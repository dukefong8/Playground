{-# LANGUAGE GHC2024           #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Root application: the shared landing page plus the sub stacks side by
-- side — home routes ('Home.Route'), the ihp-router stack under @\/app@
-- ('Todo.Route'), the servant record API under @\/servant@ ('Todo.Servant'),
-- and the sub-apps' embedded assets under @\/static@ ('Site.Static').
module Site
  ( app
  ) where

import Network.Wai (Application, pathInfo)

import Service.Hasql
import Home.Route (homeApp, notFoundResponse)
import Site.Static (staticApp)
import Todo.Route (ihpApp)
import Todo.Servant (servantApp)

app :: Pool -> Application
app pool req respond = case pathInfo req of
  [] -> homeApp req respond
  ["404"] -> homeApp req respond
  -- One embedded-asset application serves every sub-app's assets under this
  -- prefix ('Site.Static'); the trie serves the @/app@ todos.
  "static" : _ -> staticApp req respond
  "app" : _ -> ihpApp pool req respond
  "servant" : _ -> servantApp pool req respond
  _ -> respond notFoundResponse
