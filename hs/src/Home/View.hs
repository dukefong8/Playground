{-# LANGUAGE GHC2024           #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes       #-}
module Home.View
  ( index
  , page404
  ) where

import Htmx

index :: Html ()
index = [hsx|
  <h1>Welcome!</h1>
  <p><a href="/app/todos">Todos via ihp-router</a></p>
  <p><a href="/servant/todos">Todos via servant</a></p>
|]

page404 :: Html ()
page404 = [hsx|<h1>Not found...</h1>|]
