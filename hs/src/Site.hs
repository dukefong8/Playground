{-# LANGUAGE GHC2024           #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell   #-}

-- | Root application: the shared landing page plus the sub stacks side by
-- side — home routes ('Home.Route'), the ihp-router stack under @\/app@
-- ('Todo.Route'), the servant record API under @\/servant@ ('Todo.Servant'),
-- and one embedded-asset application for every sub-app under @\/static@.
module Site
  ( app
  ) where

import Language.Haskell.TH.Syntax (addDependentFile)
import Network.Wai (Application, pathInfo)
import Network.Wai.Application.Static qualified as Static
import WaiAppStatic.Storage.Embedded (mkSettings)
import WaiAppStatic.Types (MaxAge (NoStore), StaticSettings, ssMaxAge)

import Service.Hasql
import Home.Route (homeApp, notFoundResponse)
import Todo.Route (ihpApp)
import Todo.Servant (servantApp)
import Todo.Static qualified as Todo

app :: Pool -> Application
app pool req respond = case pathInfo req of
  [] -> homeApp req respond
  ["404"] -> homeApp req respond
  -- Assets are not routed per feature: one application serves every sub-app's,
  -- keyed by path under the site root. The trie serves the @/app@ todos.
  "static" : _ -> staticApp req respond
  "app" : _ -> ihpApp pool req respond
  "servant" : _ -> servantApp pool req respond
  _ -> respond notFoundResponse

-- | Every sub-app's assets, embedded once.
--
-- The splice has to live where the contributions are imported — Template
-- Haskell's stage restriction lets a splice reference imported names only — so a
-- feature declares its entries and sources (see "Todo.Static") and the embedding
-- happens here, with @NoStore@: a compile-time copy changes with every edit, so
-- a cached one is always the wrong one.
staticSettings :: StaticSettings
staticSettings =
  ( $( do
        mapM_ addDependentFile Todo.assetSources
        mkSettings (concat <$> sequenceA [Todo.assetEntries])
     )
      { ssMaxAge = NoStore }
  )

-- | Serves 'staticSettings' at the paths its entries are keyed by.
staticApp :: Application
staticApp = Static.staticApp staticSettings
