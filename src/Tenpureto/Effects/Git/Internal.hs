module Tenpureto.Effects.Git.Internal where

import           Polysemy
import           Polysemy.Error

import           Data.ByteString.Lazy           ( ByteString )
import qualified Data.ByteString.Lazy          as BS
import           Data.Text                      ( Text )
import qualified Data.Text                     as T
import qualified Data.Text.Encoding            as E
import           Data.Text.Prettyprint.Doc
import           Data.Maybe
import           Control.Monad
import           Data.Aeson                     ( FromJSON
                                                , ToJSON
                                                , (.=)
                                                , (.:)
                                                , (.:?)
                                                , (.!=)
                                                )
import qualified Data.Aeson                    as Aeson

import           Tenpureto.Effects.FileSystem
import           Tenpureto.Effects.Process


newtype GitRepository = GitRepository { repositoryPath :: Path Abs Dir }
newtype Committish = Committish Text deriving (Eq, Show)

data GitException = GitExecException { exitCode :: Int, stdOut :: Maybe ByteString, stdErr :: Maybe ByteString }
                  | HubExecException { exitCode :: Int, stdOut :: Maybe ByteString, stdErr :: Maybe ByteString }
                  | HubResponseParseException { failure :: Text, responseContent :: ByteString }

instance Pretty GitException where
    pretty (GitExecException code _ err) =
        dquotes "git"
            <+> "command failed with exit code"
            <+> pretty code
            <>  ":"
            <+> maybe emptyDoc (pretty . decodeUtf8) err
    pretty (HubExecException code _ err) =
        dquotes "hub"
            <+> "command failed with exit code"
            <+> pretty code
            <>  ":"
            <+> maybe emptyDoc (pretty . decodeUtf8) err
    pretty (HubResponseParseException msg _) =
        dquotes "hub" <+> "response cannot be parsed:" <+> pretty msg

type CmdResult = (ExitCode, ByteString, ByteString)

decodeUtf8 :: ByteString -> Text
decodeUtf8 = E.decodeUtf8 . BS.toStrict

asSuccess
    :: Member (Error GitException) r
    => CmdResult
    -> Sem r (ByteString, ByteString)
asSuccess (ExitSuccess, out, err) = return (out, err)
asSuccess (ExitFailure code, out, err) =
    throw $ GitExecException code (Just out) (Just err)

maybeSuccess :: CmdResult -> Maybe (ByteString, ByteString)
maybeSuccess (ExitSuccess  , out, err) = Just (out, err)
maybeSuccess (ExitFailure _, _  , _  ) = Nothing

asUnit :: Member (Error GitException) r => CmdResult -> Sem r ()
asUnit = void . asSuccess

asByteString :: Member (Error GitException) r => CmdResult -> Sem r ByteString
asByteString = fmap fst . asSuccess

maybeByteString :: CmdResult -> Maybe ByteString
maybeByteString = fmap fst . maybeSuccess

asLines :: Member (Error GitException) r => CmdResult -> Sem r [Text]
asLines = fmap (T.lines . decodeUtf8) . asByteString

asText :: Member (Error GitException) r => CmdResult -> Sem r Text
asText = fmap decodeUtf8 . asByteString

asFirstLineText
    :: Member (Error GitException) r => CmdResult -> Sem r (Maybe Text)
asFirstLineText = fmap listToMaybe . asLines

asFiles
    :: Members '[FileSystem, Error GitException] r
    => CmdResult
    -> Sem r [Path Rel File]
asFiles = traverse (parseRelFile . T.unpack) <=< asLines

asCommittish :: Member (Error GitException) r => CmdResult -> Sem r Committish
asCommittish = fmap (Committish . T.strip . decodeUtf8) . asByteString

asMaybeCommittish
    :: Member (Error GitException) r => CmdResult -> Sem r (Maybe Committish)
asMaybeCommittish = fmap (fmap Committish) . asFirstLineText

-- Git --

gitCmd :: Member Process r => [Text] -> Sem r CmdResult
gitCmd cmd = runCmd ("git" :| cmd)

gitRepoCmd :: Member Process r => GitRepository -> [Text] -> Sem r CmdResult
gitRepoCmd (GitRepository path) cmd =
    gitCmd (map T.pack ["-C", toFilePath path] ++ cmd)

gitInteractiveCmd
    :: Members '[Process, Error GitException] r => [Text] -> Sem r ()
gitInteractiveCmd cmd = runInteractiveCmd ("git" :| cmd) >>= \case
    ExitSuccess      -> return ()
    ExitFailure code -> throw $ GitExecException code Nothing Nothing

gitInteractiveRepoCmd
    :: Members '[Process, Error GitException] r
    => GitRepository
    -> [Text]
    -> Sem r ()
gitInteractiveRepoCmd (GitRepository path) cmd =
    gitInteractiveCmd (map T.pack ["-C", toFilePath path] ++ cmd)

-- GitHub --

data ApiMethod = ApiPost | ApiPatch

apiMethod :: ApiMethod -> Text
apiMethod ApiPost  = "POST"
apiMethod ApiPatch = "PATCH"

newtype PullRequestAssignee = PullRequestAssignee { assigneeLogin :: Text }
newtype PullRequestLabel = PullRequestLabel { labelName :: Text }
data PullRequest = PullRequest { pullRequestNumber :: Int, pullRequestAssignees :: [PullRequestAssignee], pullRequestLabels :: [PullRequestLabel] }
data ReferenceInputPayload = ReferenceInputPayload { referenceSha :: Text, referenceRef :: Maybe Text }

data PullRequestInputPayload = PullRequestInputPayload { pullRequestHead :: Text, pullRequestBase :: Text, setPullRequestTitle :: Maybe Text }
data IssueInputPayload = IssueInputPayload { setIssueAssignees :: [Text], setIssueLabels :: [Text] }

instance Pretty Committish where
    pretty (Committish c) = pretty c

instance FromJSON PullRequestAssignee where
    parseJSON (Aeson.Object v) = PullRequestAssignee <$> v .: "login"
    parseJSON _                = fail "Invalid pull request assignee response"

instance FromJSON PullRequestLabel where
    parseJSON (Aeson.Object v) = PullRequestLabel <$> v .: "name"
    parseJSON _                = fail "Invalid pull request label response"

instance FromJSON PullRequest where
    parseJSON (Aeson.Object v) =
        PullRequest
            <$> v
            .:  "number"
            <*> v
            .:? "assignees"
            .!= []
            <*> v
            .:? "labels"
            .!= []
    parseJSON _ = fail "Invalid template YAML definition"

instance ToJSON ReferenceInputPayload where
    toJSON ReferenceInputPayload { referenceSha = sha, referenceRef = ref } =
        Aeson.object $ ("sha" .= sha) : catMaybes [fmap ("ref" .=) ref]

instance ToJSON PullRequestInputPayload where
    toJSON PullRequestInputPayload { pullRequestHead = h, pullRequestBase = b, setPullRequestTitle = t }
        = Aeson.object $ ["head" .= h, "base" .= b] ++ catMaybes
            [fmap ("title" .=) t]

instance ToJSON IssueInputPayload where
    toJSON IssueInputPayload { setIssueAssignees = a, setIssueLabels = l } =
        Aeson.object ["assignees" .= a, "labels" .= l]

asApiResponse
    :: (Member (Error GitException) r, FromJSON a) => CmdResult -> Sem r a
asApiResponse = throwDecode <=< asByteString
  where
    throwDecode
        :: (Member (Error GitException) r, FromJSON a) => ByteString -> Sem r a
    throwDecode a = either
        (\f -> throw $ HubResponseParseException (T.pack f) a)
        return
        (Aeson.eitherDecode a)

hubApiCmd
    :: (Member Process r, ToJSON a)
    => GitRepository
    -> ApiMethod
    -> Text
    -> a
    -> Sem r CmdResult
hubApiCmd (GitRepository path) method endpoint input = runInputCmd
    (  "hub"
    :| [ "-C"
       , T.pack (toFilePath path)
       , "api"
       , "--method"
       , apiMethod method
       , endpoint
       , "--input"
       , "-"
       ]
    )
    (Aeson.encode input)

hubApiGetCmd
    :: Member Process r
    => GitRepository
    -> Text
    -> [(Text, Text)]
    -> Sem r CmdResult
hubApiGetCmd (GitRepository path) endpoint fields = runCmd
    (  "hub"
    :| ["-C", T.pack (toFilePath path), "api", "--method", "GET", endpoint]
    ++ (fields >>= \(key, value) -> ["--raw-field", key <> "=" <> value])
    )

createOrUpdateReference
    :: Members '[Process, Error GitException] r
    => GitRepository
    -> Committish
    -> Text
    -> Sem r ()
createOrUpdateReference repo (Committish c) reference = do
    (code, out, err) <- hubApiCmd
        repo
        ApiPost
        "/repos/{owner}/{repo}/git/refs"
        ReferenceInputPayload { referenceSha = c
                              , referenceRef = Just ("refs/heads/" <> reference)
                              }
    case code of
        ExitSuccess -> return ()
        ExitFailure 22 ->
            hubApiCmd
                    repo
                    ApiPatch
                    ("/repos/{owner}/{repo}/git/refs/heads/" <> reference)
                    ReferenceInputPayload { referenceSha = c
                                          , referenceRef = Nothing
                                          }
                >>= asUnit
        ExitFailure other ->
            throw $ HubExecException other (Just out) (Just err)
