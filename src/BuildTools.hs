-- | Various tools and utility functions to do wtih building.
module BuildTools (
        setupDir,
        runCabal, runCabalResults, runCabalStdout,
        runGhcPkg,
        initialisePackageConf,
        die, info, warn,
        StdLine(..)
    ) where

import HackageMonad
import Utils

import Control.Monad.State
import System.Directory
import System.Exit
import System.FilePath
import System.Process

import Control.Concurrent
import Control.Exception
import System.IO

-- | Setup the needed directory structure
setupDir:: String -> Hkg ()
setupDir name = do
    exists <- liftIO $ doesDirectoryExist name
    if exists
        then die (show name ++ " already exists, not overwriting")
        else liftIO $ do
            createDirectory name
            createDirectory (name </> "logs.stats")
            createDirectory (name </> "logs.build")

-- | Run cabal.
runCabal :: [String] -> Hkg ExitCode
runCabal args = do
    cabalInstall <- getCabalInstall
    x <- liftIO $ rawSystem cabalInstall args
    return x

-- | Run cabal returing the results
runCabalStdout :: [String] -> Hkg (Maybe String)
runCabalStdout args = do
    cabalInstall <- getCabalInstall
    r <- runCmdGetStdout cabalInstall args
    return r

-- | Run cabal returning the resulting output or error code
runCabalResults :: [String] -> Hkg (Either (ExitCode, [StdLine]) [String])
runCabalResults args = do
    cabalInstall <- getCabalInstall
    r <- runCmdGetResults cabalInstall args
    return r

-- | Run ghc-pkg.
runGhcPkg :: [String] -> Hkg ExitCode
runGhcPkg args = do
    ghcPkg <- getGhcPkg
    x <- liftIO $ rawSystem ghcPkg args
    return x

-- | Setup a package database
initialisePackageConf :: FilePath -> Hkg ()
initialisePackageConf fp = do
    liftIO . ignoreException $ removeFile fp
    liftIO . ignoreException $ removeDirectoryRecursive fp
    x <- runGhcPkg ["init", fp]
    case x of
        ExitSuccess -> return ()
        _ -> die ("Initialising package database in " ++ show fp ++ " failed")

-- | Print message to stdout.
info :: String -> Hkg ()
info msg = liftIO $ putStrLn msg

-- | Print message to stderr.
warn :: String -> Hkg ()
warn msg = liftIO $ hPutStrLn stderr msg

-- | Exit with error message.
die :: String -> Hkg a
die err = liftIO $ hPutStrLn stderr err >> exitWith (ExitFailure 1)

-- | Command output representation
data StdLine = Stdout String
             | Stderr String

-- | Run a cmd return its stdout results.
runCmdGetStdout :: FilePath -> [String] -> Hkg (Maybe String)
runCmdGetStdout prog args
    = liftIO
    $ do (hIn, hOut, hErr, ph) <- runInteractiveProcess prog args
                                                        Nothing Nothing
         hClose hIn
         mv <- newEmptyMVar
         sOut <- hGetContents hOut
         sErr <- hGetContents hErr
         _ <- forkIO $ (do _ <- evaluate (length sOut)
                           return ())
                        `finally`
                        putMVar mv ()
         _ <- forkIO $ (do _ <- evaluate (length sErr)
                           return ())
                        `finally`
                        putMVar mv ()
         ec <- waitForProcess ph
         takeMVar mv
         takeMVar mv
         case (ec, sErr) of
             (ExitSuccess, "") -> return $ Just sOut
             _ -> return Nothing

-- | Run a cmd returning the fullresults.
runCmdGetResults :: FilePath -> [String]
                 -> Hkg (Either (ExitCode, [StdLine]) [String])
runCmdGetResults prog args = liftIO $ do
    (hIn, hOut, hErr, ph) <- runInteractiveProcess prog args Nothing Nothing
    hClose hIn
    linesMVar <- newEmptyMVar
    lineMVar <- newEmptyMVar
    let getLines h c = do l <- hGetLine h
                          putMVar lineMVar (Just (c l))
                          getLines h c

        writeLines :: Int -- how many of stdout and stderr are till open
                   -> [StdLine]
                   -> IO ()
        writeLines 0 ls = putMVar linesMVar (reverse ls)
        writeLines n ls = do mLine <- takeMVar lineMVar
                             case mLine of
                                 Just line -> writeLines n (line : ls)
                                 Nothing   -> writeLines (n - 1) ls

    _ <- forkIO $ (hSetBuffering hOut LineBuffering >>
                   getLines hOut Stdout `onEndOfFile` return ())
                   `finally`
                   putMVar lineMVar Nothing

    _ <- forkIO $ (hSetBuffering hErr LineBuffering >>
                   getLines hErr Stderr `onEndOfFile` return ())
                   `finally`
                   putMVar lineMVar Nothing

    _ <- forkIO $ writeLines 2 []

    ec <- waitForProcess ph
    ls <- takeMVar linesMVar
    return $ case (ec, any isStderr ls) of
                (ExitSuccess, False) -> Right [ sout | Stdout sout <- ls ]
                _                    -> Left (ec, ls)

  where
    isStderr (Stdout _) = False
    isStderr (Stderr _) = True
