{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE GHC2024        #-}
module Main
  ( main
  ) where

import Network.Wai.Handler.Warp qualified as Wai
import Rapid

import App
import Database
import Logger (cleanupLogger)

-- $> main
main :: IO ()
main = do
  bracket acquirePool releasePool \pool ->
    bracket_ pass cleanupLogger $
      rapid 0 \r -> restart r "server" $
        Wai.run 8000 (app pool)
