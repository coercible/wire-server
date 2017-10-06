{-# LANGUAGE FunctionalDependencies     #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE OverloadedStrings          #-}

module Brig.Options where

import Brig.Types
import Brig.User.Auth.Cookie.Limit
import Brig.Whitelist (Whitelist (..))
import Control.Monad.Catch (catch, SomeException(..))
import Data.Yaml (FromJSON(..), (.:), (.:?))
import Data.ByteString (ByteString)
import Data.ByteString.Conversion
import Data.Int (Int64)
import Data.Maybe
import Data.Misc (HttpsUrl)
import Data.Monoid
import Data.Scientific (toRealFloat, toBoundedInteger)
import Data.Text (Text)
import Data.Text.Encoding (encodeUtf8)
import Data.Time.Clock (DiffTime, secondsToDiffTime)
import Data.Word (Word16, Word32)
import Database.V5.Bloodhound (IndexName (..))
import Network.HTTP.Client (Request, parseRequest)
import Options.Applicative
import Options.Applicative.Types (readerAsk)

import qualified Brig.Aws.Types        as Aws
import qualified Data.ByteString.Char8 as C
import qualified Data.Text             as T
import qualified Data.Yaml             as Y
import qualified Ropes.Aws             as Aws
import qualified Ropes.Nexmo           as Nexmo
import qualified Ropes.Twilio          as Twilio
import qualified Brig.ZAuth            as ZAuth

newtype ActivationTimeout = ActivationTimeout
    { activationTimeoutDiff :: DiffTime }
    deriving (Eq, Enum, Ord, Num, Real, Fractional, RealFrac, Show)

instance Read ActivationTimeout where
    readsPrec i s = case readsPrec i s of
        [(x, s')] -> [(ActivationTimeout (secondsToDiffTime x), s')]
        _         -> []

-- | Options that are consumed on startup
data Opts = Opts
    { optHost              :: !String
    , optPort              :: !Word16

      -- Cassandra
    , optCassHost          :: !String
    , optCassPort          :: !Word16
    , optCassKeyspace      :: !Text

      -- ElasticSearch
    , optElasticsearchUrl  :: !Text
    , optUserIndex         :: !IndexName

      -- RPC
    , optGalleyHost        :: !ByteString
    , optGalleyPort        :: !Word16
    , optGundeckHost       :: !ByteString
    , optGundeckPort       :: !Word16

      -- AWS
    , optAwsAccount        :: !Aws.Account
    , optAwsSesQueue       :: !Aws.SesQueue
    , optAwsInternalQueue  :: !Aws.InternalQueue
    , optAwsBlacklistTable :: !Aws.BlacklistTable
    , optAwsPreKeyTable    :: !Aws.PreKeyTable
    , optAwsKeyId          :: !(Maybe Aws.AccessKeyId)
    , optAwsSecretKey      :: !(Maybe Aws.SecretAccessKey)

      -- Email & SMS (General)
    , optTemplateDir           :: !FilePath
    , optEmailSender           :: !Email
    , optTwilioSender          :: !Text

      -- Email & SMS (User)
    , optUserActivationUrl     :: !ByteString
    , optUserTeamActivationUrl :: !ByteString
    , optUserSmsActivationUrl  :: !ByteString
    , optUserPasswordResetUrl  :: !ByteString
    , optUserInvitationUrl     :: !ByteString
    , optUserDeletionUserUrl   :: !ByteString

      -- Email & SMS (Provider)
    , optProviderHomeUrl       :: !HttpsUrl
    , optProviderActivationUrl :: !ByteString
    , optProviderApprovalUrl   :: !ByteString
    , optProviderApprovalTo    :: !Email

      -- Email (Team)
    , optTeamInvitationUrl     :: !ByteString

      -- ZAuth
    , optZAuthPrivateKeys :: !FilePath
    , optZAuthPublicKeys  :: !FilePath
    , optZAuthSettings    :: !ZAuth.Settings

      -- Misc.
    , optDiscoUrl :: Maybe String
    , optGeoDb    :: Maybe FilePath

      -- TURN
    , optTurnServers  :: !FilePath
    , optTurnSecret   :: !FilePath
    , optTurnLifetime :: !Word32

      -- Runtime settings
    , optSettings :: !Settings
    }

-- | Options that persist as runtime settings.
data Settings = Settings
    { setActivationTimeout  :: !ActivationTimeout
    , setTwilioSID          :: !Twilio.SID
    , setTwilioToken        :: !Twilio.AccessToken
    , setNexmoKey           :: !Nexmo.ApiKey
    , setNexmoSecret        :: !Nexmo.ApiSecret
    , setNexmoEndpoint      :: !Nexmo.ApiEndpoint
    , setWhitelist          :: !(Maybe Whitelist)
    , setUserMaxConnections :: !Int64
    , setCookieDomain       :: !ByteString
    , setCookieInsecure     :: !Bool
    , setUserCookieRenewAge :: !Integer
    , setUserCookieLimit    :: !CookieLimit
    , setUserCookieThrottle :: !CookieThrottle
    , setDefaultLocale      :: !Locale
    }

-- TODO: move FromJSON intances to separate module
instance FromJSON ZAuth.UserTokenTimeout where
  parseJSON (Y.Number n) =
    let defaultV = 60 * 60 * 24 * 28 -- 28 days
        bounded = toBoundedInteger n :: Maybe Int64
    in pure $ ZAuth.UserTokenTimeout $ maybe defaultV fromIntegral bounded

instance FromJSON ZAuth.SessionTokenTimeout where
  parseJSON (Y.Number n) =
    let defaultV = 60 * 60 * 24 * 1 -- 1 day
        bounded = toBoundedInteger n :: Maybe Int64
    in pure $ ZAuth.SessionTokenTimeout $ maybe defaultV fromIntegral bounded

instance FromJSON ZAuth.AccessTokenTimeout where
  parseJSON (Y.Number n) =
    let defaultV = 60 * 15 -- 15 minutes
        bounded = toBoundedInteger n :: Maybe Int64
    in pure $ ZAuth.AccessTokenTimeout $ maybe defaultV fromIntegral bounded

instance FromJSON ZAuth.ProviderTokenTimeout where
  parseJSON (Y.Number n) =
    let defaultV = 60 * 60 * 24 * 7 -- 7 days
        bounded = toBoundedInteger n :: Maybe Int64
    in pure $ ZAuth.ProviderTokenTimeout $ maybe defaultV fromIntegral bounded

instance FromJSON Aws.Account where
  parseJSON (Y.String str) =
    pure $ Aws.Account str

instance FromJSON Aws.SesQueue where
  parseJSON (Y.String str) =
    pure $ Aws.SesQueue str

instance FromJSON Aws.InternalQueue where
  parseJSON (Y.String str) =
    pure $ Aws.InternalQueue str

instance FromJSON Aws.BlacklistTable where
  parseJSON (Y.String str) =
    pure $ Aws.BlacklistTable str

instance FromJSON Aws.PreKeyTable where
  parseJSON (Y.String str) =
    pure $ Aws.PreKeyTable str

instance FromJSON Aws.AccessKeyId where
  parseJSON (Y.String str) =
    pure $ Aws.AccessKeyId $ encodeUtf8 str

instance FromJSON Aws.SecretAccessKey where
  parseJSON (Y.String str) =
    pure $ Aws.SecretAccessKey $ encodeUtf8 str

instance FromJSON ZAuth.Settings where
  parseJSON (Y.Object v) =
    ZAuth.Settings <$>
    v .: "key-index" <*>
    v .: "user-token-timeout" <*>
    v .: "session-token-timeout" <*>
    v .: "access-token-timeout" <*>
    v .: "provider-token-timeout"

instance FromJSON Opts where
  parseJSON (Y.Object v) =
    Opts <$>
    v .: "host" <*>
    v .: "port" <*>
    v .: "cassandra-host" <*>
    v .: "cassandra-port" <*>
    v .: "cassandra-keyspace" <*>
    v .: "elasticsearch-url" <*>
    v .: "user-index" <*>
    v .: "galley-host" <*>
    v .: "galley-port" <*>
    v .: "gundeck-host" <*>
    v .: "gundeck-port" <*>
    v .: "aws-account" <*>
    v .: "aws-ses-queue" <*>
    v .: "aws-internal-queue" <*>
    v .: "aws-blacklist-table" <*>
    v .: "aws-pre-key-table" <*>
    v .: "aws-key-id" <*>
    v .: "aws-secret-key" <*>
    v .: "template-dir" <*>
    v .: "email-sender" <*>
    v .: "twilio-sender" <*>
    v .: "user-activation-url" <*>
    v .: "user-sms-activation-url" <*>
    v .: "user-password-reset-url" <*>
    v .: "user-invitation-url" <*>
    v .: "user-deletion-user-url" <*>
    v .: "provider-home-url" <*>
    v .: "provider-activation-url" <*>
    v .: "provider-approval-url" <*>
    v .: "provider-approval-to" <*>
    v .: "team-invitation-url" <*>
    v .: "zauth-private-keys" <*>
    v .: "zauth-public-keys" <*>
    v .: "zauth-settings" <*>
    v .:? "disco-url" <*>
    v .:? "geo-db" <*>
    v .: "turn-servers" <*>
    v .: "turn-secret" <*>
    v .: "turn-lifetime" <*>
    v .: "settings"

instance FromJSON ActivationTimeout where
  parseJSON (Y.Number n) =
    let defaultV = 3600
        bounded = toBoundedInteger n :: Maybe Int64
    in pure $ ActivationTimeout $ secondsToDiffTime $ maybe defaultV fromIntegral bounded

instance FromJSON Twilio.SID where
  parseJSON (Y.String str) =
    pure $ Twilio.SID $ encodeUtf8 str

instance FromJSON Twilio.AccessToken where
  parseJSON (Y.String str) =
    pure $ Twilio.AccessToken $ encodeUtf8 str

instance FromJSON Nexmo.ApiKey where
  parseJSON (Y.String str) =
    pure $ Nexmo.ApiKey $ encodeUtf8 str

instance FromJSON Nexmo.ApiSecret where
  parseJSON (Y.String str) =
    pure $ Nexmo.ApiSecret $ encodeUtf8 str

instance FromJSON Nexmo.ApiEndpoint where
  parseJSON (Y.String str) =
    case str of
      "production" -> pure Nexmo.Production
      "sandbox" -> pure Nexmo.Sandbox
      _ -> pure Nexmo.Production

instance FromJSON Request where
  parseJSON (Y.String str) =
    pure $ fromMaybe "Invalid request URL" (parseRequest (T.unpack str))

instance FromJSON ByteString where
  parseJSON (Y.String str) =
    pure $ encodeUtf8 str

instance FromJSON RetryAfter where
  parseJSON (Y.Number n) =
    pure $ RetryAfter $ fromMaybe 0 (toBoundedInteger n)

instance FromJSON StdDev where
  parseJSON (Y.Number n) =
    pure $ StdDev $ toRealFloat n

instance FromJSON CookieThrottle where
  parseJSON (Y.Object v) =
    StdDevThrottle <$>
    v .: "std-dev" <*>
    v .: "retry-after"

instance FromJSON CookieLimit where
  parseJSON (Y.Number n) =
    CookieLimit <$>
    let defaultV = 0
        bounded = toBoundedInteger n :: Maybe Int64
    in pure $ maybe defaultV fromIntegral bounded

instance FromJSON Settings where
  parseJSON (Y.Object v) =
    Settings <$>
    v .: "activation-timeout" <*>
    v .: "twilio-sid" <*>
    v .: "twilio-token" <*>
    v .: "nexmo-key" <*>
    v .: "nexmo-secret" <*>
    v .: "nexmo-endpoint" <*>
    v .:? "whitelist" <*>
    v .: "user-max-connections" <*>
    v .: "cookie-domain" <*>
    v .: "cookie-insecure" <*>
    v .: "user-cookie-renew-age" <*>
    v .: "user-cookie-limit" <*>
    v .: "user-cookie-throttle" <*>
    v .: "default-locale"

instance FromJSON Whitelist where
  parseJSON (Y.Object v) =
    Whitelist <$>
    v .: "url" <*>
    v .: "user" <*>
    v .: "pass"
  parseJSON _ = pure $ Whitelist "" "" ""

parseOptions :: IO Opts
parseOptions = execParser (info (helper <*> optsParser) desc)
  where
    desc = header "Brig - User Service" <> fullDesc

    optsParser :: Parser Opts
    optsParser = Opts
        <$> (strOption $
                long "host"
                <> value "*4"
                <> showDefault
                <> metavar "HOSTNAME"
                <> help "Hostname or address to bind to")

        <*> (option auto $
                long "port"
                <> short 'p'
                <> metavar "PORT"
                <> help "Port to listen on")

        <*> (strOption $
                long "cassandra-host"
                <> metavar "HOSTNAME"
                <> help "Cassandra hostname or address")

        <*> (option auto $
                long "cassandra-port"
                <> metavar "PORT"
                <> help "Cassandra port")

        <*> (textOption $
                long "cassandra-keyspace"
                <> metavar "STRING"
                <> help "Cassandra keyspace")

        <*> (textOption $
                long "elasticsearch-url"
                <> metavar "URL"
                <> help "Elasticsearch URL")

        <*> (fmap IndexName . textOption $
                long "elasticsearch-user-index"
                <> metavar "STRING"
                <> value "directory"
                <> showDefault
                <> help "The name of the ElasticSearch user index")

        <*> (bytesOption $
                long "galley-host"
                <> metavar "HOSTNAME"
                <> help "Galley hostname")

        <*> (option auto $
                long "galley-port"
                <> metavar "PORT"
                <> help "Galley port")

        <*> (bytesOption $
                long "gundeck-host"
                <> metavar "HOSTNAME"
                <> help "Gundeck hostname")

        <*> (option auto $
                long "gundeck-port"
                <> metavar "PORT"
                <> help "Gundeck port")

        <*> (fmap Aws.Account . textOption $
                long "aws-account-id"
                <> metavar "STRING"
                <> help "AWS Account ID")

        <*> (fmap Aws.SesQueue . textOption $
                long "aws-ses-queue"
                <> metavar "STRING"
                <> help "Event feedback queue for SES (e.g. for email bounces and complaints)")

        <*> (fmap Aws.InternalQueue . textOption $
                long "aws-internal-queue"
                <> metavar "STRING"
                <> help "Event queue for internal brig generated events (e.g. user deletion)")

        <*> (fmap Aws.BlacklistTable . textOption $
                long "aws-dynamo-blacklist"
                <> metavar "STRING"
                <> help "Dynamo table for storing blacklisted user keys")

        <*> (fmap Aws.PreKeyTable . textOption $
                long "aws-dynamo-prekeys"
                <> metavar "STRING"
                <> help "Dynamo table for storing prekey data")

        <*> (optional . fmap Aws.AccessKeyId . bytesOption $
                long "aws-access-key-id"
                <> metavar "STRING"
                <> help "AWS Access Key ID")

        <*> (optional . fmap Aws.SecretAccessKey . bytesOption $
                long "aws-secret-access-key"
                <> metavar "STRING"
                <> help "AWS Secret Access Key")

        <*> (strOption $
                long "template-dir"
                <> metavar "FILE"
                <> help "Email/SMS/... template directory")

        <*> (emailOption $
                long "email-sender"
                <> metavar "STRING"
                <> help "Email sender address")

        <*> (textOption $
                long "twilio-sender"
                <> metavar "STRING"
                <> help "Twilio sender identifier (number or messaging service ID")

        <*> (bytesOption $
                long "activation-url"
                <> metavar "URL"
                <> help "Activation URL template")

        <*> (bytesOption $
                long "team-activation-url"
                <> metavar "URL"
                <> help "Team Activation URL template")

        <*> (bytesOption $
                long "sms-activation-url"
                <> metavar "URL"
                <> help "SMS activation URL template")

        <*> (bytesOption $
                long "password-reset-url"
                <> metavar "URL"
                <> help "Password reset URL template")

        <*> (bytesOption $
                long "invitation-url"
                <> metavar "URL"
                <> help "Invitation URL template")

        <*> (bytesOption $
                long "deletion-url"
                <> metavar "URL"
                <> help "Deletion URL template")

        <*> (httpsUrlOption $
                long "provider-home-url"
                <> metavar "URL"
                <> help "Provider Homepage URL")

        <*> (bytesOption $
                long "provider-activation-url"
                <> metavar "URL"
                <> help "Provider Activation URL template")

        <*> (bytesOption $
                long "provider-approval-url"
                <> metavar "URL"
                <> help "Provider Approval URL template")

        <*> (emailOption $
                long "provider-approval-to"
                <> metavar "STRING"
                <> help "Provider approval email recipient")

        <*> (bytesOption $
                long "team-invitation-url"
                <> metavar "URL"
                <> help "Team Invitation URL template")

        <*> (strOption $
                long "zauth-private-keys"
                <> metavar "FILE"
                <> help "zauth private key file"
                <> action "file")

        <*> (strOption $
                long "zauth-public-keys"
                <> metavar "FILE"
                <> help "zauth public key file"
                <> action "file")

        <*> (ZAuth.Settings
            <$> (option auto $
                    long "zauth-key-index"
                    <> metavar "INT"
                    <> value 1
                    <> showDefault
                    <> help "Secret key index to use for token creation")
            <*> (fmap ZAuth.UserTokenTimeout . option auto $
                    long "zauth-user-token-timeout"
                    <> metavar "INT"
                    <> help "User token validity timeout")
            <*> (fmap ZAuth.SessionTokenTimeout . option auto $
                    long "zauth-session-token-timeout"
                    <> metavar "INT"
                    <> help "Session token validity timeout")
            <*> (fmap ZAuth.AccessTokenTimeout . option auto $
                    long "zauth-access-token-timeout"
                    <> metavar "INT"
                    <> help "Access token validity timeout")
            <*> (fmap ZAuth.ProviderTokenTimeout . option auto $
                    long "zauth-provider-token-timeout"
                    <> metavar "INT"
                    <> help "Access token validity timeout"))

        <*> (optional $ strOption $
                long "disco-url"
                <> metavar "URL"
                <> help "klabautermann url")

        <*> (optional $ option auto $
                long "geodb"
                <> metavar "FILE"
                <> help "GeoDB file path")

        <*> (strOption $
                long "turn-servers"
                <> metavar "FILE"
                <> help "Line separated file with IP addresses of the available turn servers"
                <> action "file")

        <*> (strOption $
                long "turn-secret"
                <> metavar "FILE"
                <> help "TURN shared secret file path"
                <> action "file")

        <*> (option auto $
                long "turn-token-lifetime"
                <> metavar "INT"
                <> value 3600
                <> showDefault
                <> help "Number of seconds TURN credentials should be valid.")
        
        <*> settingsParser

    settingsParser :: Parser Settings
    settingsParser = Settings
        <$> (option auto $
                long "activation-timeout"
                <> metavar "SECONDS"
                <> value (ActivationTimeout (secondsToDiffTime 3600))
                <> help "Activation timeout in seconds")

        <*> (fmap Twilio.SID . bytesOption $
                long "twilio-sid"
                <> metavar "STRING"
                <> help "Twilio SID")

        <*> (fmap Twilio.AccessToken . bytesOption $
                long "twilio-token"
                <> metavar "STRING"
                <> help "Twilio API token")

        <*> (fmap Nexmo.ApiKey . bytesOption $
                long "nexmo-key"
                <> metavar "STRING"
                <> help "Nexmo API key")

        <*> (fmap Nexmo.ApiSecret . bytesOption $
                long "nexmo-secret"
                <> metavar "STRING"
                <> help "Nexmo API secret")

        <*> (option toNexmoEndpoint $
                long "nexmo-endpoint"
                <> value Nexmo.Production
                <> metavar "STRING"
                <> showDefaultWith (const "production")
                <> help "Nexmo API environment: sandbox | production")

        <*> (optional $ Whitelist
                <$> (option requestUrl $
                        long "whitelist-url"
                        <> help "URL of a service providing a whitelist of allowed email addresses and phone numbers.")

                <*> (bytesOption $
                        long "whitelist-user"
                        <> metavar "STRING"
                        <> value ""
                        <> help "Username for accessing the whitelist")

                <*> (bytesOption $
                        long "whitelist-pass"
                        <> metavar "STRING"
                        <> value ""
                        <> help "Password for accessing the whitelist"))

        <*> (option auto $
                long "user-connection-limit"
                <> metavar "INT"
                <> help "Max. number of sent/accepted connections per user."
                <> value 1000)

        <*> (bytesOption $
                long "cookie-domain"
                <> metavar "STRING"
                <> help "The domain to restrict cookies to.")

        <*> (switch $
                long "cookie-insecure"
                <> help "Allow plain HTTP transmission of cookies (for testing purposes only).")

        <*> (option auto $
                long "user-cookie-renew-age"
                <> metavar "INT"
                <> help "Minimum age of a user cookie before it is renewed during token refresh.")

        <*> (fmap CookieLimit . option auto $
                long "user-cookie-limit"
                <> metavar "INT"
                <> value 32
                <> showDefault
                <> help "Max. # of cookies per user and cookie type.")

        <*> (StdDevThrottle <$>
                (fmap StdDev . option auto $
                    long "user-cookie-min-deviation"
                    <> metavar "SECONDS"
                    <> value 3000
                    <> showDefault
                    <> help "Min. standard deviation cookie creation")
            <*> (fmap RetryAfter . option auto $
                    long "user-cookie-retry-after"
                    <> metavar "SECONDS"
                    <> value 86400
                    <> showDefault
                    <> help "Wait time when the min deviation is violated"))

        <*> (localeOption $
                long "default-locale"
                <> metavar "STRING"
                <> value "en"
                <> showDefault
                <> help "Default locale to use (e.g. when selecting templates)")

    bytesOption :: Mod OptionFields String -> Parser ByteString
    bytesOption = fmap C.pack . strOption

    textOption :: Mod OptionFields String -> Parser Text
    textOption = fmap T.pack . strOption

    httpsUrlOption :: Mod OptionFields String -> Parser HttpsUrl
    httpsUrlOption = fmap (fromMaybe (error "Invalid HTTPS URL") . fromByteString) . bytesOption

    localeOption :: Mod OptionFields String -> Parser Locale
    localeOption = fmap (fromMaybe (error "Ensure proper default locale is used") . parseLocale . T.pack) . strOption

    emailOption :: Mod OptionFields String -> Parser Email
    emailOption = fmap (fromMaybe (error "Ensure proper email address is used") . parseEmail . T.pack) . strOption

    toNexmoEndpoint :: ReadM Nexmo.ApiEndpoint
    toNexmoEndpoint = readerAsk >>= \s -> case s of
        "production" -> return Nexmo.Production
        "sandbox"    -> return Nexmo.Sandbox
        other        -> readerError $ "Unsupported Nexmo environment: " <> other

    requestUrl :: ReadM Request
    requestUrl = readerAsk >>= maybe (fail "Invalid request URL") pure . parseRequest
