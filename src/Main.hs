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
import qualified Control.Concurrent.STM.SSem as SSem
import qualified Data.Time.Clock.POSIX as POSIX
import Data.IORef
import Foreign.C
import Foreign.C.String
import Foreign.Marshal.Array
--import qualified TH as CH

bufSize :: Int
bufSize = 464

numWorkers :: Int
numWorkers = 1

numAllocs :: Int
numAllocs = 1

newtype AbsFilePath = AbsFilePath { unAbsFilePath :: FilePath } deriving Show
type WorkUnit = (FileStatus, FilePath, AbsFilePath)

l `addF` r = FileCount $ unFileCount l + unFileCount r
l `addD` r = DirCount $ unDirCount l + unDirCount r

worker :: UChan.InChan WorkUnit -> UChan.OutChan WorkUnit -> IORef Int -> Count -> Int -> IO ()
worker wchan rchan work (countF,countD) configNumAllocs = do
    void $ forkIO $ do
--        buffers <- mapM (\_ -> return $ allocaBytes bufSize) [1..configNumAllocs]
        buffers <- mapM (\_ -> mallocBytes bufSize) [1..configNumAllocs]
        forever $ (do
            firstWork <- UChan.readChan rchan
            let getMore acc !i = do
                    if i == configNumAllocs
                       then return acc
                       else do
                            f <- UChan.tryReadChan rchan
                            e <- UChan.tryRead $ fst f
                            case e of
                                Just e' -> getMore (e':acc) (i+1)
                                Nothing -> return acc
            allWorks <- getMore [firstWork] 1

            let filteredWorks = filter (\(_, r', _) -> not $ isPrefixOf "." r') allWorks
                (dirs, files) = partition (\(fs', _, _) -> isDirectory fs') filteredWorks

            contents <- forM dirs $ \(_,_,a') -> do
                l <- getDirectoryContents $ unAbsFilePath a'
                return (a', l)

            let toWork :: (AbsFilePath, [FilePath]) -> IO [WorkUnit]
                toWork (a', w') = do
                    forM w' $ \w'' -> do
                            let aw = unAbsFilePath a' </> w''
                            fs' <- getFileStatus aw
                            return (fs', w'', AbsFilePath $ aw)

            realContent <- mapM toWork contents
            let flatRealContent = concat realContent
            atomicModifyIORef' work $ (\v -> (v + length flatRealContent, ()))
            UChan.writeList2Chan wchan flatRealContent
            atomicModifyIORef' countD (\v -> (v `addD` (DirCount $ length dirs), ()))


            let bufferWorks = zip buffers files
--            mapM_ (\(buffer, (_,_,a')) -> buffer $ \b -> withCString (unAbsFilePath a') $ \fp -> c_hs_read_bytes bufSize fp b) bufferWorks
            strs <- mapM (\(_, (_,_,a')) -> newCString $ unAbsFilePath a') bufferWorks
            withArray strs $ \strs' -> withArray buffers $ \buffers' -> c_hs_read_many_bytes bufSize (length strs) strs' buffers'
            atomicModifyIORef' countF (\v -> (v `addF` (FileCount $ length bufferWorks), ()))
            atomicModifyIORef' work $ (\v -> (v - length allWorks, ()))
            ) `catch` (\e -> putStrLn $ show (e :: SomeException))

newtype FileCount = FileCount { unFileCount :: Int }
newtype DirCount = DirCount { unDirCount :: Int }

type Count = (IORef FileCount, IORef DirCount)

timer :: Count -> IO ()
timer (countF, countD) = do
  putStrLn "Starting TImer"
  totalF <- newIORef $ FileCount 0
  totalD <- newIORef $ DirCount 0
  void $ async $ forever $ do
    s <- POSIX.getPOSIXTime
    threadDelay 1000000
    fc <- atomicModifyIORef' countF $ \v -> (FileCount 0, v)
    dc <- atomicModifyIORef' countD $ \v -> (DirCount 0, v)

    tfc <- atomicModifyIORef' totalF $ \v -> (v `addF` fc, v)
    tdc <- atomicModifyIORef' totalD $ \v -> (v `addD` dc, v)

    let curFiles = fc
        curDirs = dc
        totalFiles = fc `addF` tfc
        totalDirs = dc `addD` tdc
    e <- POSIX.getPOSIXTime
    let diff = fromIntegral $ floor $ e - s
    putStrLn $ "Loaded Files ("
            ++ show (unFileCount totalFiles)
            ++ ", "
            ++ show ((fromIntegral $ unFileCount curFiles) / diff)
            ++ "/second) Directories ("
            ++ show (unDirCount totalDirs)
            ++ ", "
            ++ show ((fromIntegral $ unDirCount curDirs) / diff)
            ++ "/second)"

main :: IO ()
main = do
  args <- getArgs
  (wchan, rchan) <- UChan.newChan
  work <- newIORef 0
  countF <- newIORef $ FileCount 0
  countD <- newIORef $ DirCount 0
  _ <- timer (countF,countD)
  let mkWork f = do
        fs <- getFileStatus f
        return $ (fs, "", AbsFilePath f)
  (configNumWorkers, configNumAllocs) <- case args of
    [path] -> do
        w <- mkWork path
        atomicModifyIORef' work (\v -> (v + 1, ()))
        UChan.writeChan wchan w
        return (numWorkers, numAllocs)
    [path, nw] -> do
        w <- mkWork path
        atomicModifyIORef' work (\v -> (v + 1, ()))
        UChan.writeChan wchan w
        return $ (read nw, numAllocs)
    [path, nw, na] -> do
        w <- mkWork path
        atomicModifyIORef' work (\v -> (v + 1, ()))
        UChan.writeChan wchan w
        return $ (read nw, read na)

  mapM_ (\_ -> worker wchan rchan work (countF,countD) configNumAllocs) [1..configNumWorkers]

  forever $ do
        val <- atomicModifyIORef' work (\v -> (v,v))
        when (val == 0) $
         fail "BooM"
        putStrLn ("Outstanding" ++ show val)
        threadDelay 1000000
  return ()

foreign import ccall "hs_read_bytes"
    c_hs_read_bytes :: Int -> CString -> Ptr CChar -> IO Int
    
foreign import ccall "hs_read_many_bytes"
    c_hs_read_many_bytes :: Int -> Int -> Ptr CString -> Ptr (Ptr CChar) -> IO Int
