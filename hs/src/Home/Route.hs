{-# LANGUAGE GHC2024           #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes       #-}
{-# LANGUAGE TemplateHaskell   #-}

-- | The site-level home and not-found routes, served through ihp-router and
-- shared by the root dispatcher ('Site'), the ihp-router fallback and the
-- servant handlers.
module Home.Route
  ( HomeRoute (..)
  , homeRouteTrie
  , dispatchHome
  , homeApp
  , homeResponse
  , notFoundResponse
  ) where

import Network.HTTP.Types (StdMethod (..), status200, status404)
import Network.Wai (Application, Response)

import Home.View (index, page404)
import Htmx.Prelude (htmlResponse)
import IHP.Router.WAI (HasPath (..), routeTrieMiddleware, routes)

data HomeRoute
  = HomeAction
  | NotFoundAction
  deriving (Eq, Show)

$(pure []) -- declaration-group boundary

[routes|
GET /     HomeAction
GET /404  NotFoundAction
|]

dispatchHome :: HomeRoute -> Application
dispatchHome HomeAction _req respond =
  respond homeResponse
dispatchHome NotFoundAction _req respond =
  respond notFoundResponse

-- | The home stack as a plain WAI 'Application', composed by 'Site'
-- alongside the todo stacks. Unknown paths fall back to the shared 404.
homeApp :: Application
homeApp =
  routeTrieMiddleware (homeRouteTrie dispatchHome) fallback
  where
    fallback _req respond = respond notFoundResponse

homeResponse :: Response
homeResponse = htmlResponse status200 index

notFoundResponse :: Response
notFoundResponse = htmlResponse status404 page404
