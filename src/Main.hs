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
import Options.Applicative     ( Parser
                               , execParser
                               , argument
                               , info
                               , helper
                               , fullDesc
                               , help
                               , switch
                               , metavar
                               , str
                               , long
                               , short
                               , value
                               , strOption
                               , option
                               , auto
                               )
import Data.Monoid ((<>))
import Data.String.Utils

data CliArguments = CliArguments
    { dir :: !FilePath
    , workers :: !Int
    , count :: !Bool
    }

parseArgs :: IO CliArguments
parseArgs = execParser $ info (helper <*> parseCliArgs) fullDesc

parseCliArgs :: Parser CliArguments
parseCliArgs =
    let directory = strOption
            ( long "directory"
            <> short 'd'
            <> help "Directory to operate on"
            )
        workers =  option auto
            ( long "workers"
            <> short 'w'
            <> help "number of workers"
            <> value 100
            )
        count = option auto
            ( long "count"
            <> short 'c'
            <> help "run the counter/timer"
            <> value False
            )
    in CliArguments <$> directory <*> workers <*> count


bufSize :: Int
bufSize = 464


newtype AbsFilePath = AbsFilePath { unAbsFilePath :: FilePath } deriving Show
type WorkUnit = (FileStatus, FilePath, AbsFilePath)

l `addF` r = FileCount $ unFileCount l + unFileCount r
l `addD` r = DirCount $ unDirCount l + unDirCount r

worker :: UChan.InChan WorkUnit -> UChan.OutChan WorkUnit -> TVar Int -> Maybe Count -> IO ()
worker wchan rchan work counters = do
    void $ forkIO $ do
        buffer <- mallocBytes bufSize
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
                       let purgeContents c = do
                                if c == "1h" || c == "5m"
                                   then do
                                       fs <- getFileStatus c
                                       return $ if isRegularFile fs
                                            then False
                                            else True
                                   else return True
                       filtered <- filterM (\x -> do
                                    p <- purgeContents x
                                    let p' = (not $ isPrefixOf "." x)
                                    return $ p || p') contents

                       mapM_ addWork filtered
                       void $ forM counters $ \(_,countD) ->
                            atomicModifyIORef' countD (\v -> (v `addD` DirCount 1, ()))
                   else do
                       --withCString (unAbsFilePath a) $ \c -> c_hs_read_bytes bufSize c buffer
                       let absPath = unAbsFilePath a
                           paths = [absPath, replace "10s" "5m" absPath, replace "10s" "1h" absPath]
                       strs <- mapM newCString paths
                       withArray strs $ \ps -> c_hs_read_bytes bufSize (length paths) ps buffer
                       mapM free strs
                       void $ forM counters $ \(countF,_) ->
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
  args <- parseArgs
  (wchan, rchan) <- UChan.newChan
  work <- newTVarIO 0
  countF <- newIORef $ FileCount 0
  countD <- newIORef $ DirCount 0
  when (count args) $
    timer (countF,countD)
  let mkWork f = do
        fs <- getFileStatus f
        return $ (fs, "", AbsFilePath f)

  w <- mkWork (dir args)
  atomically $ modifyTVar' work (+1)
  UChan.writeChan wchan w

  let counters = if count args
        then Just $ (countF, countD)
        else Nothing
  mapM_ (\_ -> worker wchan rchan work counters) [1..(workers args)]

  atomically $ do
      val <- readTVar work
      when (val /= 0) $
         retry
  return ()

foreign import ccall "hs_read_bytes"
    c_hs_read_bytes :: Int -> Int -> Ptr CString -> Ptr CChar -> IO Int
