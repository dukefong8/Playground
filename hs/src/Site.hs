{-# LANGUAGE GHC2024           #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Root application: the shared landing page plus the sub stacks side by
-- side — home routes ('Home.Route'), the todo filter script ('Todo.Filter'),
-- ihp-router todos under @\/app@ ('Todo.Route') and the servant record API
-- under @\/servant@ ('Todo.Servant').
module Site
  ( app
  ) where

import Network.Wai (Application, pathInfo)

import Database
import Home.Route (homeApp, notFoundResponse)
import Todo.Filter (filterApp)
import Todo.Route (ihpApp)
import Todo.Servant (servantApp)

app :: Pool -> Application
app pool req respond = case pathInfo req of
  [] -> homeApp req respond
  ["404"] -> homeApp req respond
  "todo" : _ -> filterApp req respond
  "app" : _ -> ihpApp pool req respond
  "servant" : _ -> servantApp pool req respond
  _ -> respond notFoundResponse
