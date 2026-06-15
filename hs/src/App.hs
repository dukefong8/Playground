{-# LANGUAGE BlockArguments      #-}
{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE GHC2024             #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE PatternSynonyms     #-}
{-# LANGUAGE QuasiQuotes         #-}
{-# LANGUAGE TypeApplications    #-}

module App
  ( app
  , appRoutes
  , index
  , page404
  ) where

import Prelude hiding (Handler)

import Database
import Htmx
import Network.Wai (Application)
import Servant.API
import Servant.Server
import Servant.Server.Internal.Handler (pattern MkHandler)

import Todo

type HelloAPI = "hello" :> Capture "name" Text :> Get '[HTML] (Html ())

type AppRoutes =
       Get '[HTML] (Html ())
  :<|> "htmx" :> HelloAPI
  :<|> TodoRoutes
  :<|> CaptureAll "notFound" Text :> Get '[HTML] (Html ())

appRoutes :: Proxy AppRoutes
appRoutes = Proxy

helloHandler :: Pool -> Text -> Handler (Html ())
helloHandler _pool name = pure [hsx|<h1 id="hello">Hello, {name}!</h1>|]

app :: Pool -> Application
app pool =
  serve appRoutes $
    index
      :<|> helloHandler pool
      :<|> todoServer pool
      :<|> notFound

index :: Handler (Html ())
index = pure [hsx|<h1>Welcome!</h1>|]

page404 :: Html ()
page404 = [hsx|<h1>Not found...</h1>|]

notFound :: [Text] -> Handler (Html ())
notFound _segments =
  MkHandler $ pure $ Left err404 { errBody = renderBS page404 }
