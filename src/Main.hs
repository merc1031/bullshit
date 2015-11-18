{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Main where
import Data.Maybe
import Control.Concurrent
import Control.Concurrent.STM
import Control.Concurrent.Async
import Control.Monad
import Control.Exception
import Data.Foldable
import Data.List
import Foreign.Marshal.Alloc
import GHC.Ptr
import System.Directory
import System.Environment (getArgs)
import System.FilePath
import System.IO
import System.Posix.Files
import System.FilePath.Find ((==?), (/=?), (&&?), (<=?), depth, fileType, filePath, FileType(..))
import qualified System.FilePath.Find as Find
import qualified Control.Concurrent.Chan.Unagi as UChan
import qualified Control.Concurrent.Chan.Unagi.NoBlocking as NonBlocking
import System.IO.Unsafe
import Control.DeepSeq
import qualified Data.ByteString.Lazy as BSL

bufSize :: Int
bufSize = 464

workers :: Int
workers = 80

allocs :: Int
allocs = 30

worker :: NonBlocking.InChan FilePath -> NonBlocking.Stream FilePath -> (TVar Int, TVar Int) -> Int -> IO ()
worker wchan rstream (countF,countD) _ = do
  void $ async $ do
    putStrLn "worker started"
    let act strIn = do
--        paths <- fmap catMaybes $ mapM (\_ -> do
--                                       e <- fmap fst $ NonBlocking.tryReadChan rchan
--                                       NonBlocking.tryRead e
--                                       ) [0..allocs]
--            putStrLn "Stil Working"
            let readSome !i ps rstr = do
                    h <- NonBlocking.tryReadNext rstr
                    case h of
                        NonBlocking.Next p rstr' -> case i >= allocs of
                                            False -> readSome (i+1) (p:ps) rstr'
                                            True -> return $ (p:ps, rstr')
                        NonBlocking.Pending -> return (ps,rstr)
            (paths, strOut) <- readSome 0 [] strIn
            (files, dirs) <- foldlM (\(fs, ds) p -> do
                    stat <- getFileStatus p
                    let ds' = if isDirectory stat
                        then p:ds
                        else ds
                    let fs' = if isRegularFile stat
                        then p:fs
                        else fs
                    return (fs',ds')
                                    )
                                    ([], [])
                                    paths
            when ((length dirs) /= 0) $ do
--            forM dirs $ \path -> do
                feedWorker wchan dirs
                atomically $ modifyTVar' countD (+ (length dirs))


            when ((length files) /= 0) $ do
                v <- forM (files) $ \path -> do
                    do
                                               h <- openBinaryFile path ReadMode
                                               c <- readContents h
                                               hClose h
                                               return (h, c)--return () --withBinaryFile path ReadMode (readContents buf)
--                mapM (\(h,!c) -> do
--                    hClose h
--                    ) v
    --            v `seq` return ()
--                putStrLn $ show v
                atomically $ modifyTVar' countF (+ (length files))

            yield
            act strOut
    act rstream `catch` (\(e :: SomeException) -> putStrLn $ show e)
            
--writer :: UChan.InChan FilePath -> FilePath -> IO ()
--writer chan path = do
--  void $ async $ do
--    putStrLn "writer started"
--    roots <- Find.find (depth <=? 0) (fileType ==? Directory &&? filePath /=? path) path
--    putStrLn $ show roots
--    mapConcurrently (\p -> do
--        putStrLn ("A path" ++ p)
--        paths <- Find.find (fileType ==? Directory) (fileType ==? RegularFile) p
--        putStrLn $ "Paths were found!" ++ show (length paths)
--        UChan.writeList2Chan chan paths
--                    ) roots


feedWorker :: NonBlocking.InChan FilePath -> [String] -> IO ()
feedWorker c paths = do
  contents <- concat <$> mapM (\path -> do
                              l <- getDirectoryContents path
                              return $ map (path </>) . filter (not . isPrefixOf ".") $ l
                              ) paths
--                              fmap ((path </>) . filter (not . isPrefixOf ".")) <$> getDirectoryContents path) paths
  NonBlocking.writeList2Chan c contents
  return ()

readContents :: Handle -> IO _
readContents h = do
  hSetBuffering h $ BlockBuffering $ Just bufSize
  a <- BSL.hGet h bufSize
  return a

timer :: (TVar Int, TVar Int) -> IO ()
timer (countF, countD) = do
  putStrLn "Starting TImer"
  totalF <- newTVarIO 0
  totalD <- newTVarIO 0
  void $ async $ forever $ do
    putStrLn "Top of timer"
    threadDelay 1000000
    putStrLn "After delay"
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

main :: IO ()
main = do
  args <- getArgs
  (wchan, rchan) <- NonBlocking.newChan
  countF <- newTVarIO 0
  countD <- newTVarIO 0
  _ <- timer (countF,countD)
  case args of
    [path] -> NonBlocking.writeChan wchan path --writer wchan path --atomically $ writeTChan chan path
    _      -> NonBlocking.writeChan wchan "."  --writer wchan "." --atomically $ writeTChan chan "."
  threadDelay 1000000
  workerStreams <- NonBlocking.streamChan workers rchan
  mapM_ (\str -> worker wchan str (countF,countD) 0) workerStreams

  _ <- getLine
  return ()
