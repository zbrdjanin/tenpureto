{-# LANGUAGE QuasiQuotes #-}

module Tenpureto.TemplaterTest where

import           Test.Tasty
import           Test.Tasty.HUnit

import           Polysemy
import           Polysemy.Error

import qualified Data.Set                      as Set
import qualified Data.HashMap.Strict.InsOrd    as InsOrdHashMap
import qualified Control.Exception             as E

import           Path

import           Tenpureto.Effects.FileSystem
import           Tenpureto.Effects.Logging
import           Tenpureto.Templater

test_translateFile :: [TestTree]
test_translateFile =
    let Right settings = runTest $ compileSettings TemplaterSettings
            { templaterFromVariables = InsOrdHashMap.singleton "A" "bbb-ccc-ddd"
            , templaterToVariables   = InsOrdHashMap.singleton "A" "xxx-yyy"
            , templaterExcludes      = Set.empty
            }
        mv = runTest . translateFile settings
    in  [ testCase "should replace in file name"
            $   mv [relfile|a-bbb-ccc-ddd-e.txt|]
            @?= Right [relfile|a-xxx-yyy-e.txt|]
        , testCase "should replace in path"
            $   mv [relfile|a/bbb/ccc/ddd/e/f.txt|]
            @?= Right [relfile|a/xxx/yyy/e/f.txt|]
        ]

test_excludes :: [TestTree]
test_excludes =
    let
        assertMatches a b = assertBool
            ("expected pattern: " ++ show a ++ " to match file: " ++ show b)
            (compileExcludes (Set.singleton a) b)
        assertNotMatches a b = assertBool
            ("expected pattern: " ++ show a ++ " to match file: " ++ show b)
            (not $ compileExcludes (Set.singleton a) b)
    in
        [ testGroup
            "wildcard"
            [ testCase "should match a file" $ assertMatches "*" [relfile|a|]
            , testCase "should match a file in a dir"
                $ assertMatches "*" [relfile|a/b|]
            ]
        , testGroup
            "double wildcard"
            [ testCase "should match zero dirs"
                $ assertMatches "/a/**/b" [relfile|a/b|]
            , testCase "should match one dir"
                $ assertMatches "/a/**/b" [relfile|a/c/b|]
            , testCase "should match two dirs"
                $ assertMatches "/a/**/b" [relfile|a/c/d/b|]
            ]
        , testGroup
            "root dir"
            [ testCase "should match a file in a dir"
                $ assertMatches "/a/" [relfile|a/b|]
            , testCase "should not match a file"
                $ assertNotMatches "/a/" [relfile|a|]
            ]
        , testGroup
            "root path"
            [ testCase "should match a file in a dir"
                $ assertMatches "/a" [relfile|a/b|]
            , testCase "should match a file" $ assertMatches "/a" [relfile|a|]
            ]
        , testGroup
            "dir"
            [ testCase "should match a dir" $ assertMatches "a/" [relfile|a/b|]
            , testCase "should not match a file"
                $ assertNotMatches "a/" [relfile|b/a|]
            , testCase "should match a file in a dir"
                $ assertMatches "a/" [relfile|a/b|]
            , testCase "should match a file in a dir when starts with a dot"
                $ assertMatches ".a/" [relfile|.a/b|]
            ]
        , testGroup
            "path"
            [ testCase "should match a file in a dir"
                $ assertMatches "a" [relfile|b/a|]
            , testCase "should match a file" $ assertMatches "a" [relfile|a/b|]
            , testCase "should match a file in a dir"
                $ assertMatches "a" [relfile|a/b|]
            , testCase "should match a file in a dir when starts with a dot"
                $ assertMatches ".a" [relfile|.a/b|]
            ]
        , testCase "should not match invalid patterns"
            $ assertNotMatches "[" [relfile|a|]
        ]

data NotImplemented = NotImplemented deriving (Eq, Show)
instance E.Exception NotImplemented

runFileSystemPure
    :: Sem (FileSystem ': r) a -> Sem (Error E.SomeException ': r) a
runFileSystemPure = reinterpret $ \case
    ParseRelFile             filePath -> sendE $ Path.parseRelFile filePath
    EnsureDir                _        -> throwE NotImplemented
    EnsureEmptyDir           _        -> throwE NotImplemented
    ResolveDir               _        -> throwE NotImplemented
    IsSymlink                _        -> throwE NotImplemented
    GetSymbolicLinkDirTarget _        -> throwE NotImplemented
    CreateDirectoryLink _ _           -> throwE NotImplemented
    CopyPermissions     _ _           -> throwE NotImplemented
    RenameFile          _ _           -> throwE NotImplemented
    RemoveFile                _       -> throwE NotImplemented
    ReadFileAsByteString      _       -> throwE NotImplemented
    ReadFileAsMaybeByteString _       -> throwE NotImplemented
    WriteFileAsByteString _ _         -> throwE NotImplemented
    OpenBinaryTempFile    _ _         -> throwE NotImplemented
    CreateSystemTempDir _             -> throwE NotImplemented
    RemoveDirRecur      _             -> throwE NotImplemented
    HPutByteString _ _                -> throwE NotImplemented
    HClose _                          -> throwE NotImplemented
  where
    sendE :: Either e a -> Sem (Error e ': r) a
    sendE = either throw return
    throwE :: E.Exception e => e -> Sem (Error E.SomeException ': r) a
    throwE e = throw $ E.SomeException e

runTest :: Sem '[Logging, FileSystem, Error String] a -> Either String a
runTest =
    run . runError . runErrorAsAnother show . runFileSystemPure . runNoLogging