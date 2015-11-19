{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
module Main where
import Data.Maybe
import Control.Concurrent
import Control.Concurrent.MVar
import Control.Concurrent.STM
import Control.Concurrent.Async
import Control.Monad
import Control.Exception
import Data.Foldable
import Data.List
import Foreign.Marshal.Alloc
import Foreign.Marshal.Array
import GHC.Ptr
import System.Directory
import System.Environment (getArgs)
import System.FilePath
import System.IO
import System.Posix.Files
import System.FilePath.Find ((==?), (/=?), (&&?), (<=?), (>=?), depth, fileType, filePath, FileType(..))
import qualified System.FilePath.Find as Find
import qualified Control.Concurrent.Chan.Unagi as UChan
import qualified Control.Concurrent.Chan.Unagi.NoBlocking as NonBlocking
import System.IO.Unsafe
import Control.DeepSeq
import qualified Data.ByteString.Lazy as BSL
import qualified Data.ByteString as BS
import System.IO.MMap
import Data.Int
import Data.Word8

bufSize :: Int
bufSize = 464

bufSize64 :: Int64
bufSize64 = 464

workers :: Int
workers = 1

allocs :: Int
allocs = 1

type WorkUnit = (FilePath, FilePath)

bsPutStdErr = BS.hPut stderr

worker :: NonBlocking.InChan [WorkUnit] -> NonBlocking.Stream [WorkUnit] -> UChan.InChan [Handle] -> MVar Bool -> (TVar Int, TVar Int) -> Int -> IO ()
worker wchan rstream wcollector start (countF,countD) numAllocs = do
  void $ async $ do
    buffers <- mapM (\_ -> return $ allocaBytes bufSize) [0..numAllocs]
    let act strIn = do
            let readSome !i ps rstr = do
                    h <- NonBlocking.tryReadNext rstr
                    case h of
                        NonBlocking.Next p rstr' -> case i >= numAllocs of
                                            False -> readSome (i+1) (p:ps) rstr'
                                            True -> return $ (p:ps, rstr')
                        NonBlocking.Pending -> return (ps,rstr)
            (paths', strOut) <- readSome 1 [[]] strIn
            let paths = concat paths'


            when ((length paths) /= 0) $ do
--                vs <- forM (paths) $ \((root,path)) -> do
--                        let path' = root </> path
--                        !v <- mmapFileByteString path' (Just (0, bufSize))
--                        evaluate v
--                        --withBinaryFile path' ReadMode $ \h -> buf $ \b -> readContents h b
                vs <- forM (zip buffers paths) $ \(buf, (root,path)) -> do
                        let path' = root </> path
--                        !v <- withBinaryFile path' ReadMode $ \h -> buf $ \b -> do
                        v <- buf $ \b -> do
                            h <- openBinaryFile path' ReadMode
                            readContents h b
                            !a <- peekArray bufSize b
                            return h
                        return v
                UChan.writeChan wcollector vs
                atomically $ modifyTVar' countF (+ (length paths))
                void $ tryPutMVar start True

            yield
            act strOut
    act rstream `catch` (\(e :: SomeException) -> putStrLn $ show e)


readContents :: Handle -> Ptr Word8 -> IO _
readContents h b = do
  hSetBuffering h $ BlockBuffering $ Just bufSize
  a <- hGetBufNonBlocking h b bufSize
  return a

timer :: (TVar Int, TVar Int) -> IO ()
timer (countF, countD) = do
  putStrLn "Starting TImer"
  totalF <- newTVarIO 0
  totalD <- newTVarIO 0
  void $ async $ forever $ do
    threadDelay 1000000
    (latest, total, latestD, total') <- atomically $ do
      x <- readTVar countF
      z <- readTVar countD
      writeTVar countF 0
      writeTVar countD 0
      y <- readTVar totalF
      w <- readTVar totalD
      modifyTVar' totalF (+x)
      modifyTVar' totalD (+z)
      return (x, x+y, z, z+w)
    putStrLn $ "Loaded Files (" ++ show total ++ ", " ++ show latest ++ "/second) Directories (" ++ show total' ++ ", " ++ show latestD ++ "/second)"

type ReaderData = FilePath

readers :: NonBlocking.InChan [WorkUnit] -> TVar Int -> FilePath -> IO ()
readers wchan countD path = do
    roots <- Find.find (depth <=? 0) (depth >=? 1 &&? fileType ==? Directory &&? filePath /=? path) path
    (mwchan, mrchan) <- UChan.newChan
    UChan.writeList2Chan mwchan roots
    mapM_ (\_ -> reader wchan mwchan mrchan countD) roots

reader :: NonBlocking.InChan [WorkUnit] -> UChan.InChan ReaderData -> UChan.OutChan ReaderData -> TVar Int -> IO ()
reader wchan mwchan mrchan countD = do
    void $ async $ do
        let act !iter = do
                command <- UChan.tryReadChan mrchan
                res <- UChan.tryRead $ fst command
                case res of
                    Just path -> do
                            contents <- filter (not . isPrefixOf ".") <$> getDirectoryContents path
                            (files, dirs) <- foldlM (\(fs, ds) p -> do
                                    let p' = path </> p
                                    stat <- getFileStatus p'
                                    let ds' = if isDirectory stat
                                        then p':ds
                                        else ds
                                    let fs' = if isRegularFile stat
                                        then (path,p):fs
                                        else fs
                                    return (fs',ds')
                                                    )
                                                    ([], [])
                                                    contents
                            atomically $ modifyTVar' countD (+ (length dirs))
                            NonBlocking.writeChan wchan files
                            UChan.writeList2Chan mwchan dirs
                            yield
                            act iter
                    Nothing -> do
                        if iter > 10
                        then do
                            yield
                        else do threadDelay 1000000
                                act (iter + 1)
        act 0


collector :: UChan.OutChan [Handle] -> MVar Bool -> MVar Bool -> IO ()
collector rcollector start done = do
    putStrLn "Start Collector"
    void $ async $ do
        let act !iter !cs' = do
                _ <- readMVar start
                cse <- UChan.tryReadChan rcollector
                cse' <- UChan.tryRead $ fst cse
                case cse' of
                  Just cs -> do
                    yield
                    act 0 (cs:cs')
                  Nothing -> do
                    if iter > 20
                       then do
                           putStrLn "Collector in final phase"
--                           bsPutStdErr $ BSL.concat $ concat cs'
                           mapM_ hClose $ concat cs'
                           putStrLn "Collector done"
                           putMVar done True
                       else do
                           threadDelay 1000000
                           act (iter + 1) cs'
        act 0 [[]]

main :: IO ()
main = do
  args <- getArgs
  (wchan, rchan) <- NonBlocking.newChan
  (wcollector, rcollector) <- UChan.newChan
  start <- newEmptyMVar
  done <- newEmptyMVar
  countF <- newTVarIO 0
  countD <- newTVarIO 0
  _ <- timer (countF,countD)
  _ <- collector rcollector start done
  (w', a') <- case args of
    []     -> do
        --NonBlocking.writeChan wchan (".", "")  --writer wchan "." --atomically $ writeTChan chan "." 
        readers wchan countD "."
        return (workers, allocs)
    [path] -> do
        --NonBlocking.writeChan wchan ("", path) --writer wchan path --atomically $ writeTChan chan path
        readers wchan countD path
        return (workers, allocs)
    [path, w, a] -> do
        --NonBlocking.writeChan wchan ("", path) --writer wchan path --atomically $ writeTChan chan path
        readers wchan countD path
        return (read w, read a)

  threadDelay 1000000
  workerStreams <- NonBlocking.streamChan w' rchan
  mapM_ (\str -> worker wchan str wcollector start (countF,countD) a') workerStreams

  _ <- takeMVar done
  return ()
