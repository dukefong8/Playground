{-# LANGUAGE DerivingVia       #-}
{-# LANGUAGE GHC2024           #-}
{-# LANGUAGE OverloadedStrings #-}

module Http
  ( RouteHandler
  , RouteError(..)
  , runRouteHandler
  , throwRouteError
  , runDbOr500
  , parseRequestBody
  , checkedInt64
  , htmlResponse
  , viewResponse
  , errorResponse
  ) where

import Database (Pool, Session, runDb)
import Network.HTTP.Types (Status, hContentType, status200, status400, status500)
import Network.Wai (Request, Response, responseLBS, strictRequestBody)
import Web.FormUrlEncoded (FromForm, urlDecodeAsForm)

data RouteError = RouteError Status LByteString
  deriving stock Show

newtype RouteHandler a = RouteHandler { unRouteHandler :: IO (Either RouteError a) }
  deriving (Functor, Applicative, Monad, MonadIO) via ExceptT RouteError IO

runRouteHandler :: RouteHandler a -> IO (Either RouteError a)
runRouteHandler = unRouteHandler

throwRouteError :: Status -> LByteString -> RouteHandler a
throwRouteError status body = RouteHandler $ pure $ Left (RouteError status body)

runDbOr500 :: Pool -> Session a -> RouteHandler a
runDbOr500 pool session = do
  result <- liftIO $ runDb pool session
  case result of
    Left err -> throwRouteError status500 $ encodeUtf8 (show err :: Text)
    Right a  -> pure a

parseRequestBody :: FromForm a => Request -> RouteHandler a
parseRequestBody req = do
  body <- liftIO $ strictRequestBody req
  case urlDecodeAsForm body of
    Left err -> invalidBody err
    Right a  -> pure a

checkedInt64 :: Integer -> Maybe Int64
checkedInt64 value
  | value < fromIntegral (minBound :: Int64) = Nothing
  | value > fromIntegral (maxBound :: Int64) = Nothing
  | otherwise = Just (fromIntegral value)

htmlResponse :: Status -> LByteString -> Response
htmlResponse status body =
  responseLBS status [(hContentType, "text/html; charset=utf-8")] body

viewResponse :: (a -> LByteString) -> a -> Response
viewResponse renderHtml value =
  htmlResponse status200 (renderHtml value)

errorResponse :: RouteError -> Response
errorResponse (RouteError status body) =
  responseLBS status [(hContentType, "text/plain; charset=utf-8")] body

invalidBody :: Text -> RouteHandler a
invalidBody err =
  throwRouteError status400 $ encodeUtf8 ("Invalid request body: " <> err)
