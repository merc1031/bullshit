module Main where
import Control.Concurrent (forkIO)
import Control.Concurrent.Async
import Control.Monad.IO.Class
import Control.Monad.Trans.Resource
import Data.Conduit (Sink, Conduit, Source, await, awaitForever, yield)
import Data.Conduit.Async
import qualified Data.Conduit.Combinators as DCC
import Data.Conduit.Filesystem
import Data.List
import Data.Time.Clock
import Foreign.Marshal.Alloc
import System.Directory
import System.Environment (getArgs)
import System.FilePath
import System.IO
import System.Posix.Files

bufSize :: Int
bufSize = 464

readContents :: FilePath -> IO ()
readContents path = allocaBytes bufSize $ \buf ->
  withFile path ReadMode $ \h -> do
    hSetBinaryMode h True
    hSetBuffering h $ BlockBuffering $ Just bufSize
    _ <- hGetBuf h buf bufSize
    return ()

sink :: Sink FilePath IO ()
sink = awaitForever $ \path -> liftIO $ forkIO $ readContents path

mark :: Int
mark = 100

timer :: Int -> UTCTime -> Conduit FilePath IO FilePath
timer total time = do
  x' <- await
  case x' of
    Just x -> do
      yield x
      if total `mod` mark == 0
        then do
          newtime <- liftIO getCurrentTime
          let diff = diffUTCTime newtime time
              rate = truncate $ fromIntegral mark / diff :: Integer
          liftIO $ putStrLn $ show total ++ " total, " ++ show rate ++ " per second"
          timer (total + 1) newtime
        else
          timer (total + 1) time
    Nothing -> return ()

source :: FilePath -> Source IO FilePath
source path = do
  contents <- liftIO $ map (path </>) . filter (not . isPrefixOf ".") <$> getDirectoryContents path
  statted <- liftIO $ zip contents <$> mapConcurrently getFileStatus contents
  let (dirs', files') = partition (isDirectory . snd) statted
      dirs  = map fst dirs'
      files = map fst files'
  DCC.yieldMany files
  mapM_ source dirs

crawl :: FilePath -> IO ()
crawl path = do
  --let source = sourceDirectoryDeep False path
  time <- getCurrentTime
  source path =$=& timer 1 time $$& sink

main :: IO ()
main = do
  args <- getArgs
  case args of
    [path] -> crawl path
    _      -> crawl "."
  return ()
