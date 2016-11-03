{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies      #-}
--------------------------------------------------------------------------------
-- |
-- Module      :  Network.MQTT.ServerStack
-- Copyright   :  (c) Lars Petersen 2016
-- License     :  MIT
--
-- Maintainer  :  info@lars-petersen.net
-- Stability   :  experimental
--------------------------------------------------------------------------------
module Network.Stack.Server where

import           Control.Concurrent.Async
import           Control.Concurrent.MVar
import qualified Control.Exception           as E
import           Control.Monad
import qualified Data.ByteString             as BS
import qualified Data.ByteString.Lazy        as BSL
import           Data.Typeable
import qualified Data.X509                   as X509
import           Foreign.Storable
import qualified Network.TLS                 as TLS
import qualified Network.WebSockets          as WS
import qualified Network.WebSockets.Stream   as WS
import qualified System.Socket               as S

data TLS a
data WebSocket a

class (Typeable a, Show (ServerConnectionInfo a)) => ServerStack a where
  type ServerMessage a
  data Server a
  data ServerConfig a
  data ServerException a
  data ServerConnection a
  type ServerConnectionInfo a
  -- | Creates a new server from a configuration and passes it to a handler function.
  --
  --   The server given to the handler function shall be bound and in
  --   listening state. The handler function is usually a
  --   `Control.Monad.forever` loop that accepts and handles new connections.
  --
  --   > withServer config $ \server->
  --   >   forever $ withConnection handleConnection
  withServer     :: ServerConfig a -> (Server a -> IO b) -> IO b
  -- | Waits for and accepts a new connection from a listening server and passes
  --   it to a handler function.
  --
  --   This operation is blocking until the lowest layer in the stack accepts
  --   a new connection. The handlers of all other layers are executed within
  --   an `Control.Concurrent.Async.Async` which is returned. This allows
  --   the main thread waiting on the underlying socket to block just as long
  --   as necessary. Upper layer protocol handshakes (TLS etc) will be executed
  --   in a new thread.
  --
  --   > withServer config $ \server-> forever $
  --   >   future <- withConnection server handleConnection
  --   >   putStrLn "The lowest layer accepted a new connection!"
  --   >   async $ do
  --   >       result <- wait future
  --   >       putStrLn "The connection handler returned:"
  --   >       print result
  withConnection :: Server a -> (ServerConnection a -> ServerConnectionInfo a -> IO b) -> IO (Async b)
  flush          :: ServerConnection a -> IO ()
  send           :: ServerConnection a -> ServerMessage a -> IO ()
  receive        :: ServerConnection a -> Int -> IO (ServerMessage a)

instance (Storable (S.SocketAddress f), Show (S.SocketAddress f), S.Family f, S.Type t, S.Protocol p, Typeable f, Typeable t, Typeable p) => ServerStack (S.Socket f t p) where
  type ServerMessage (S.Socket f t p) = BS.ByteString
  data Server (S.Socket f t p) = SocketServer
    { socketServer       :: !(S.Socket f t p)
    , socketServerConfig :: !(ServerConfig (S.Socket f t p))
    }
  data ServerConfig (S.Socket f t p) = SocketServerConfig
    { socketServerConfigBindAddress :: !(S.SocketAddress f)
    , socketServerConfigListenQueueSize :: Int
    }
  data ServerException (S.Socket f t p) = SocketServerException !S.SocketException
  data ServerConnection (S.Socket f t p) = SocketServerConnection !(S.Socket f t p)
  type ServerConnectionInfo (S.Socket f t p) = S.SocketAddress f
  withServer c handle = E.bracket
    (SocketServer <$> S.socket <*> pure c)
    (S.close . socketServer) $ \server-> do
      S.bind (socketServer server) (socketServerConfigBindAddress $ socketServerConfig server)
      S.listen (socketServer server) (socketServerConfigListenQueueSize $ socketServerConfig server)
      handle server
  withConnection server handle =
    E.bracketOnError (S.accept (socketServer server)) (S.close . fst) $ \(connection, info)->
      async (handle (SocketServerConnection connection) info `E.finally` S.close connection)
  flush =
    const (pure ())
  send (SocketServerConnection s) = sendAll
    where
      sendAll bs = do
        sent <- S.send s bs S.msgNoSignal
        when (sent < BS.length bs) $ sendAll (BS.drop sent bs)
  receive (SocketServerConnection s) i = S.receive s i S.msgNoSignal

data TlsServerConnectionInfo a
   = TlsServerConnectionInfo {
      tlsTransportServerConnectionInfo :: a
    , tlsCertificateChain              :: Maybe X509.CertificateChain
    } deriving (Eq, Show)

instance (ServerStack a, ServerMessage a ~ BS.ByteString) => ServerStack (TLS a) where
  type ServerMessage (TLS a) = ServerMessage a
  data Server (TLS a) = TlsServer
    { tlsTransportServer            :: Server a
    , tlsServerConfig               :: ServerConfig (TLS a)
    }
  data ServerConfig (TLS a) = TlsServerConfig
    { tlsTransportConfig            :: ServerConfig a
    , tlsServerParams               :: TLS.ServerParams
    }
  data ServerException (TLS a) = TlsServerException
  data ServerConnection (TLS a) = TlsServerConnection
    { tlsTransportConnection        :: ServerConnection a
    , tlsContext                    :: TLS.Context
    }
  type ServerConnectionInfo (TLS a) = TlsServerConnectionInfo (ServerConnectionInfo a)
  withServer config handle =
    withServer (tlsTransportConfig config) $ \server->
      handle (TlsServer server config)
  withConnection server handle =
    withConnection (tlsTransportServer server) $ \connection info-> do
      let backend = TLS.Backend {
          TLS.backendFlush = flush connection
        , TLS.backendClose = pure () -- backend gets closed automatically
        , TLS.backendSend  = send connection
        , TLS.backendRecv  = receive connection
        }
      mvar <- newEmptyMVar
      context <- TLS.contextNew backend (tlsServerParams $ tlsServerConfig server)
      TLS.contextHookSetCertificateRecv context (putMVar mvar)
      TLS.handshake context
      certificateChain <- tryTakeMVar mvar
      x <- handle
        (TlsServerConnection connection context)
        (TlsServerConnectionInfo info certificateChain)
      TLS.bye context
      pure x
  flush conn     = TLS.contextFlush (tlsContext conn)
  send conn bs   = TLS.sendData     (tlsContext conn) (BSL.fromStrict bs)
  receive conn _ = TLS.recvData     (tlsContext conn)

data WebSocketServerConnectionInfo a
  = WebSocketServerConnectionInfo
    { wsTransportServerConnectionInfo :: a
    , wsRequestHead                   :: WS.RequestHead
    } deriving (Show)

instance (ServerStack a, ServerMessage a ~ BS.ByteString) => ServerStack (WebSocket a) where
  type ServerMessage (WebSocket a) = BS.ByteString
  data Server (WebSocket a) = WebSocketServer
    { wsTransportServer            :: Server a
    }
  data ServerConfig (WebSocket a) = WebSocketServerConfig
    { wsTransportConfig            :: ServerConfig a
    }
  data ServerException (WebSocket a) = WebSocketServerException
  data ServerConnection (WebSocket a) = WebSocketServerConnection
    { wsTransportConnection        :: ServerConnection a
    , wsConnection                 :: WS.Connection
    }
  type ServerConnectionInfo (WebSocket a) = WebSocketServerConnectionInfo (ServerConnectionInfo a)
  withServer config handle =
    withServer (wsTransportConfig config) $ \server->
      handle (WebSocketServer server)
  withConnection server handle =
    withConnection (wsTransportServer server) $ \connection info-> do
      let readSocket = (\bs-> if BS.null bs then Nothing else Just bs) <$> receive connection 4096
      let writeSocket Nothing   = undefined
          writeSocket (Just bs) = send connection (BSL.toStrict bs)
      stream <- WS.makeStream readSocket writeSocket
      pendingConnection <- WS.makePendingConnectionFromStream stream (WS.ConnectionOptions $ pure ())
      acceptedConnection <- WS.acceptRequest pendingConnection
      x <- handle
        (WebSocketServerConnection connection acceptedConnection)
        (WebSocketServerConnectionInfo info $ WS.pendingRequest pendingConnection)
      WS.sendClose acceptedConnection ("Thank you for flying Haskell." :: BS.ByteString)
      pure x
  flush conn     = flush (wsTransportConnection conn)
  send conn      = WS.sendBinaryData (wsConnection conn)
  receive conn _ = WS.receiveData (wsConnection conn)

{-
instance Request (ServerConnection (S.Socket f t p)) where

instance (Request (ServerConnection a)) => Request (ServerConnection (TLS a)) where
  requestSecure             = const True
  requestCertificateChain   = tlsCertificateChain
  requestHeaders a          = requestHeaders (tlsTransportConnection a)

instance (Request (ServerConnection a)) => Request (ServerConnection (WebSocket a)) where
  requestSecure conn        = requestSecure (wsTransportConnection conn)
  requestCertificateChain a = requestCertificateChain (wsTransportConnection a)
  requestHeaders conn       = WS.requestHeaders $ WS.pendingRequest (wsPendingConnection conn)
-}