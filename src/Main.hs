{-# LANGUAGE BangPatterns      #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
module Main (main) where

import Control.Concurrent      (yield)
import Control.Monad.Primitive (PrimState)
import Data.Bits               (complement, shiftL, shiftR, (.&.))
import Data.Char               (ord)
import Data.Char               (isSpace)
import Data.Word               (Word64, Word8)
import Foreign.C.Types         (CSize (..))
import Foreign.Ptr             (Ptr, castPtr)
import Foreign.Storable        (peek, pokeElemOff)
import Numeric                 (showHex)
import System.Directory        (createDirectoryIfMissing)
import System.FilePath         (takeDirectory, (</>))

import qualified Codec.Compression.Zlib   as Zlib
import qualified Control.Concurrent.Async as A
import qualified Crypto.Hash.SHA1         as SHA1
import qualified Data.ByteString          as BS
import qualified Data.ByteString.Lazy     as LBS
import qualified Data.ByteString.Base16   as Base16
import qualified Data.ByteString.Char8    as BS8
import qualified Data.ByteString.UTF8     as UTF8
import qualified Data.Primitive           as Prim
import qualified System.Process           as Proc

-------------------------------------------------------------------------------
-- Some static data
-------------------------------------------------------------------------------

-- prefix0 :: Prefix
-- prefix0 = Prefix
--     { prefixV = 0xe0eeffc0
--     , prefixM = 0xf0ffffff
--     }

-- | @xbadc0de@
prefix0 :: Prefix
prefix0 = Prefix
    { prefixV = 0xe00ddcba
    , prefixM = 0xf0ffffff
    }

-------------------------------------------------------------------------------
-- Git handling
-------------------------------------------------------------------------------

gitObjectPath :: String -> FilePath
gitObjectPath (x:y:zs) = ".git" </> "objects" </> [x,y] </> zs
gitObjectPath _        = error "gitObjectPath: invalid object hash given"

writeObject :: BS.ByteString -> IO ()
writeObject contents = do
    putStrLn $ "Writing new git object " ++ digest ++ " with contents"
    BS.putStr contents

    let objpath = gitObjectPath digest
    createDirectoryIfMissing True (takeDirectory objpath)

    LBS.writeFile objpath $ Zlib.compress $ LBS.fromStrict contents

  where
    digest = BS8.unpack (Base16.encode (SHA1.hash contents))

-------------------------------------------------------------------------------
-- Main
-------------------------------------------------------------------------------

main :: IO ()
main = do
    commithash     <- Proc.readProcess "git" ["rev-parse", "HEAD"] ""
    commitcontents <- Proc.readProcess "git" ["cat-file", "-p", strip commithash] ""

    let contents :: BS.ByteString
        contents = UTF8.fromString commitcontents

    putStrLn "Looking for salt for commit object:"
    BS.putStr contents

    let starts = [ shiftL p 60 | p <- [ 0 .. threadsN - 1 ] ]
    asyncs <- traverse (A.async . worker contents prefix0) starts
    (_, res) <- A.waitAny asyncs

    writeResult res

  where
    threadsN :: Word64
    threadsN = 16

writeResult :: Result -> IO ()
writeResult Result {..} = do
    putStrLn $ "Result found after " ++ show (resultStep .&. complement (shiftL 0xf 60)) ++ " steps"
    writeObject resultContents

strip :: String -> String
strip = filter (not . isSpace)

-------------------------------------------------------------------------------
-- Worker
-------------------------------------------------------------------------------

data Prefix = Prefix
    { prefixV :: !Word64 -- ^ value
    , prefixM :: !Word64 -- ^ mask
    }
  deriving Show

data Result = Result
    { resultStep     :: !Word64
    , resultContents :: !BS.ByteString
    , resultDigest   :: !BS.ByteString
    }
  deriving Show

-- worker is overengineered.
-- But its loop barely allocates.
--
worker
    :: BS.ByteString  -- ^ commit contents
    -> Prefix         -- ^ prefix
    -> Word64
    -> IO Result
worker payload Prefix {..} !step0 =
    BS.useAsCStringLen template $ \(ptr, ptrlen) -> do
        ba <- Prim.newPinnedByteArray 20 -- SHA-1 is 20 bytes
        aux (castPtr ptr) ptrlen ba step0
  where
    aux :: Ptr Word8 -> Int
        -> Prim.MutableByteArray (PrimState IO)
        -> Word64
        -> IO Result
    aux !ptr !ptrlen !out !step = do
        -- write salt into template
        pokeElemOff ptr (off +  0) (Prim.indexPrimArray base64alphabet $ fromIntegral (shiftR step 0  .&. 0x3f))
        pokeElemOff ptr (off +  1) (Prim.indexPrimArray base64alphabet $ fromIntegral (shiftR step 6  .&. 0x3f))
        pokeElemOff ptr (off +  2) (Prim.indexPrimArray base64alphabet $ fromIntegral (shiftR step 12 .&. 0x3f))
        pokeElemOff ptr (off +  3) (Prim.indexPrimArray base64alphabet $ fromIntegral (shiftR step 18 .&. 0x3f))
        pokeElemOff ptr (off +  4) (Prim.indexPrimArray base64alphabet $ fromIntegral (shiftR step 24 .&. 0x3f))
        pokeElemOff ptr (off +  5) (Prim.indexPrimArray base64alphabet $ fromIntegral (shiftR step 30 .&. 0x3f))
        pokeElemOff ptr (off +  6) (Prim.indexPrimArray base64alphabet $ fromIntegral (shiftR step 36 .&. 0x3f))
        pokeElemOff ptr (off +  7) (Prim.indexPrimArray base64alphabet $ fromIntegral (shiftR step 42 .&. 0x3f))
        pokeElemOff ptr (off +  8) (Prim.indexPrimArray base64alphabet $ fromIntegral (shiftR step 48 .&. 0x3f))
        pokeElemOff ptr (off +  9) (Prim.indexPrimArray base64alphabet $ fromIntegral (shiftR step 54 .&. 0x3f))
        pokeElemOff ptr (off + 10) (Prim.indexPrimArray base64alphabet $ fromIntegral (shiftR step 60 .&. 0x3f))

        -- calculate sha1 of the contents
        let outptr = Prim.mutableByteArrayContents out
        c_crypto_hash_sha1 ptr (fromIntegral ptrlen) outptr

        -- peek first element, as Word64
        w64 <- peek (castPtr outptr) :: IO Word64
        let pfx = w64 .&. prefixM

        if pfx == prefixV .&. prefixM
        then do
            contents <- BS.packCStringLen (castPtr ptr, ptrlen)
            digest   <- BS.packCStringLen (castPtr outptr, 20)

            -- these are debug messages.
            -- print contents
            -- print (Base16.encode digest, Base16.encode (SHA1.hash contents))
            print (showHex w64 "", showHex pfx "")

            return Result
                { resultStep     = step
                , resultContents = contents
                , resultDigest   = digest
                }

        else do
            yield -- we yield; not sure if it's needed but may help 'withAny'
            aux ptr ptrlen out (step + 1)

    -- Creating the template
    len :: Int
    len = BS.length payload
        + 2  -- two newlines
        + 5  -- "PoW: "
        + 11 -- base64 encoded "salt"

    -- offset to salt
    off :: Int
    off = BS.length template - 12

    -- template is construct as bytestring
    -- it's irrelevant how it's done
    template :: BS.ByteString
    template = BS.concat
        [ "commit "
        , BS8.pack (show len)
        , "\NUL"
        , payload
        , "\nPoW: ZZZZZZZZZZZ\n"
        ]

-- one stop solution, no need to think about ctx struct
foreign import ccall "sha1.h hs_cryptohash_sha1" c_crypto_hash_sha1 :: Ptr Word8 -> CSize -> Ptr Word8 -> IO ()

base64alphabet :: Prim.PrimArray Word8
base64alphabet
    = Prim.primArrayFromList
    $ map (fromIntegral . ord) "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
