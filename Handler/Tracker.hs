{-# LANGUAGE TupleSections #-}
module Handler.Tracker where

import Prelude
import Yesod
import qualified Network.Wai as Wai
import Control.Monad
import Control.Applicative
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Lazy.Char8 as LBC
import Network.Socket (SockAddr (..))
import Data.Word (Word32)
import Data.Bits
import System.Random (randomRIO)

import Foundation (DBPool, HasDB (getDBPool), withDB, withDBPool, Transaction)
import qualified Model as Model
import Model.Tracker
import qualified Benc as Benc
import qualified WorkQueue as WQ

data TrackerApp = TrackerApp
    { trackerDBPool :: DBPool 
    , trackerQueue :: WQ.Queue
    }

mkYesod "TrackerApp" [parseRoutes|
                      /announce AnnounceR GET
                      /scrape ScrapeR GET
                      |]

instance Yesod TrackerApp where
    makeSessionBackend _ = return Nothing

instance HasDB TrackerApp where
    getDBPool = trackerDBPool <$> getYesod

makeTrackerApp :: DBPool -> IO TrackerApp
makeTrackerApp pool = 
    TrackerApp pool `fmap` WQ.makeQueue


newtype RepBenc = RepBenc Benc.BValue

instance HasReps RepBenc where
    chooseRep (RepBenc v) _ = 
        return ("application/x-bittorrent",
                ContentBuilder (Benc.toBuilder v) Nothing
               )

-- TODO: insert own seeder!
-- TODO: support key parameter
getAnnounceR :: Handler RepBenc
getAnnounceR = do
  query <- getRawQuery
  addr <- getRemoteAddr
  let q :: BC.ByteString -> Maybe BC.ByteString
      q = join . (`lookup` query)
      qi :: Read r => BC.ByteString -> Maybe r
      qi name = do v <- q name
                   case readsPrec 0 $ BC.unpack v of
                     [(r, "")] -> return r
                     _ -> Nothing
      mTr = TrackerRequest <$>
            Model.InfoHash <$> q "info_hash" <*>
            (PeerId <$> q "peer_id") <*>
            pure addr <*>
            qi "port" <*>
            qi "uploaded" <*>
            qi "downloaded" <*>
            qi "left" <*>
            pure (q "event") <*>
            pure (maybe False (const True) $ q "compact")
  case mTr of
    Nothing ->
        return $ RepBenc $
        Benc.BDict [(Benc.BString "failure",
                     Benc.BString "Invalid tracker request"),
                    (Benc.BString "interval",
                     Benc.BInt 0xffff)]
    Just tr ->
        do let isSeeder = trLeft tr == 0
           -- Read first
           (peers, scraped) <- 
               withDB $ \db ->
                   do peers <- getPeers (trInfoHash tr) isSeeder db
                      scraped <- safeScrape (trInfoHash tr) db
                      return (peers, scraped)
           -- Write in background
           q <- trackerQueue `fmap` getYesod
           pool <- getDBPool
           liftIO $ WQ.enqueue q $
             withDBPool pool $ announcePeer tr
           -- Assemble response
           let (peers4, peers6)
                   | trCompact tr =
                       ( Benc.BString $ LBC.fromChunks $ concat
                         [[addr', portToByteString port']
                          | TrackedPeer _ (Peer4 addr') port' <- peers]
                       , Benc.BString $ LBC.fromChunks $ concat
                         [[addr', portToByteString port']
                          | TrackedPeer _ (Peer6 addr') port' <- peers]
                       )
                   | otherwise =
                       let g peerId addr' port' =
                               Benc.BDict [("peer id", Benc.BString $ LBC.fromChunks [peerId]),
                                           ("ip", Benc.BString $ LBC.fromChunks [addr']),
                                           ("port", Benc.BInt $ fromIntegral port')]
                       in ( Benc.BList $
                            [g peerId addr' port'
                             | TrackedPeer (PeerId peerId) (Peer4 addr') port' <- peers]
                          , Benc.BList $
                            [g peerId addr' port'
                             | TrackedPeer (PeerId peerId) (Peer6 addr') port' <- peers]
                          )
           interval <- liftIO $ randomRIO (540, 600)
           return $ RepBenc $
                  Benc.BDict [ ("peers", peers4)
                             , ("peers6", peers6)
                             , ("interval", Benc.BInt interval)
                             , ("complete", Benc.BInt $ scrapeSeeders scraped)
                             , ("incomplete", Benc.BInt $ scrapeLeechers scraped)
                             , ("downloaded", Benc.BInt $ scrapeDownloaded scraped)
                             ]

getScrapeR :: Handler RepBenc
getScrapeR = do
  query <- getRawQuery
  let mInfoHash = Model.InfoHash `fmap` 
                  (join $ "info_hash" `lookup` query)
  (infoHash, scraped) <-
      case mInfoHash of
        Nothing ->
            notFound
        Just infoHash ->
            (infoHash, ) `fmap`
            withDB (safeScrape infoHash)

  return $ RepBenc $
         Benc.BDict 
         [("host",
           Benc.BDict 
           [(Benc.BString $ LBC.fromChunks [Model.unInfoHash infoHash],
             Benc.BDict 
             [("incomplete", Benc.BInt $ scrapeLeechers scraped),
              ("complete", Benc.BInt $ scrapeSeeders scraped),
              ("downloaded", Benc.BInt $ scrapeDownloaded scraped)]
            )]
          )]
             
safeScrape :: Model.InfoHash -> Transaction ScrapeInfo
safeScrape infoHash db = 
    (head . (++ [ScrapeInfo 0 0 0 0])) `fmap` 
    scrape infoHash db
         
getRawQuery :: Handler [(BC.ByteString, Maybe BC.ByteString)]
getRawQuery = 
    Wai.queryString `fmap`
    waiRequest
    
getRemoteAddr :: Handler PeerAddress
getRemoteAddr =
  do remote <- Wai.remoteHost `fmap`
               waiRequest
     return $
            case remote of
              SockAddrInet _ haddr ->
                  Peer4 $ wordToByteString haddr
              SockAddrInet6 _ _ (0, 0, 0xffff, haddr) _ ->
                  Peer4 $ wordToByteString haddr
              SockAddrInet6 _ _ (h6, h6', h6'', h6''') _ ->
                  Peer6 $ B.concat [ wordToByteString h6
                                   , wordToByteString h6'
                                   , wordToByteString h6''
                                   , wordToByteString h6'''
                                   ]
              SockAddrUnix _ ->
                  error "Cannot use tracker over unix sockets :-)"
    
wordToByteString :: Word32 -> B.ByteString
wordToByteString w =
    B.pack $
    map (fromIntegral . (.&. 0xFF) . (w `shiftR`) . (* 8)) $
    reverse [0..3]
    
portToByteString :: Int -> B.ByteString
portToByteString p =
  let p' = fromIntegral p
  in B.pack [ (p' `shiftR` 8) .&. 0xFF
            , p' .&. 0xFF
            ]
