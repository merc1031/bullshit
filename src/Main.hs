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
--import qualified TH as CH

bufSize :: Int
bufSize = 464

numWorkers :: Int
numWorkers = 1

newtype AbsFilePath = AbsFilePath { unAbsFilePath :: FilePath } deriving Show
type WorkUnit = (FileStatus, FilePath, AbsFilePath)

l `addF` r = FileCount $ unFileCount l + unFileCount r
l `addD` r = DirCount $ unDirCount l + unDirCount r

worker :: UChan.InChan WorkUnit -> UChan.OutChan WorkUnit -> TVar Int -> Count -> IO ()
worker wchan rchan work (countF,countD) = do
    void $ forkIO $ do
--        buffer <- return $ allocaBytes bufSize
        forever $ do
            (fs, r, a) <- UChan.readChan rchan
            when (not $ isPrefixOf "." r) $ do
                if isDirectory fs
                   then do
                       let addWork w = do
                            let aw = unAbsFilePath a </> w
                            atomically $ modifyTVar' work (+1)
                            wfs <- getFileStatus aw
                            UChan.writeChan wchan (wfs, w, AbsFilePath aw)

                       contents <- getDirectoryContents $ unAbsFilePath a
                       mapM_ addWork contents
--                       atomically $ modifyTVar' countD (`addD` DirCount 1)
                       atomicModifyIORef' countD (\v -> (v `addD` DirCount 1, ()))
                   else do
--                       withBinaryFile (unAbsFilePath a) ReadMode $ \h -> buffer $ \b -> do
--                            hSetBuffering h $ BlockBuffering $ Just bufSize
--                            void $ hGetBufNonBlocking h b bufSize
--                       void $ fmap (BSL.take (fromIntegral bufSize)) $ BSL.readFile $ unAbsFilePath a
                       withCString (unAbsFilePath a) $ \c -> c_hs_read_bytes bufSize c
--                       atomically $ modifyTVar' countF (`addF` FileCount 1)
                       atomicModifyIORef' countF (\v -> (v `addF` FileCount 1, ()))
            atomically $ modifyTVar' work (\x -> x - 1)

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
--    (curFiles, totalFiles, curDirs, totalDirs) <- atomically $ do
--      fc <- readTVar countF
--      dc <- readTVar countD
--      writeTVar countF $ FileCount 0
--      writeTVar countD $ DirCount 0
--      tfc <- readTVar totalF
--      tdc <- readTVar totalD
--      modifyTVar' totalF (`addF` fc)
--      modifyTVar' totalD (`addD` dc)
--      return (fc, fc `addF` tfc, dc, dc `addD` tdc)
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
  work <- newTVarIO 0
  countF <- newIORef $ FileCount 0
  countD <- newIORef $ DirCount 0
  _ <- timer (countF,countD)
  let mkWork f = do
        fs <- getFileStatus f
        return $ (fs, "", AbsFilePath f)
  configNumWorkers <- case args of
    [path] -> do
        w <- mkWork path
        atomically $ modifyTVar' work (+1)
        UChan.writeChan wchan w
        return (numWorkers)
    [path, nw] -> do
        w <- mkWork path
        atomically $ modifyTVar' work (+1)
        UChan.writeChan wchan w
        return $ read nw

  mapM_ (\_ -> worker wchan rchan work (countF,countD)) [1..configNumWorkers]

  atomically $ do
      val <- readTVar work
      when (val /= 0) $
         retry
  return ()

foreign import ccall "hs_read_bytes"
    c_hs_read_bytes :: Int -> CString -> IO Int
