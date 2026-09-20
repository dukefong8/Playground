{-# LANGUAGE OverloadedStrings #-}

-- | The todo filter's client script, contributed to the site's static
-- application (in 'Site') rather than served by a route of its own.
module Todo.Static
  ( todoFilterAsset
  , todoFilterUrl
  , assetSources
  , assetEntries
  ) where

import WaiAppStatic.Storage.Embedded (EmbeddableEntry (..))

-- | The script: its source under the project root and — since the site serves
-- that directory at @\/static@ — the path it is served at, which is how 'Site'
-- keys the entry.
todoFilterAsset :: FilePath
todoFilterAsset = "static/todo_filter.cljs"

-- | Where the page head loads the script from.
--
-- Derived here rather than handed down by 'Site': a view cannot import the root
-- module (it dispatches to the route modules that import the views), so an
-- asset's URL belongs next to the key it is embedded under.
todoFilterUrl :: Text
todoFilterUrl = "/" <> toText todoFilterAsset

-- | Registered through 'Site' so an edit to the source recompiles the embedding.
assetSources :: [FilePath]
assetSources = [todoFilterAsset]

-- | The script as an embedded entry. The empty etag means "no etag": clients
-- re-fetch every time, since a cached copy is always the wrong copy while the
-- file changes with every edit.
assetEntries :: IO [EmbeddableEntry]
assetEntries = do
  cljs <- readFileLBS todoFilterAsset
  pure
    [ EmbeddableEntry
        { eLocation = toText todoFilterAsset
        , eMimeType = "application/x-scittle"
        , eContent = Left ("", cljs)
        }
    ]
