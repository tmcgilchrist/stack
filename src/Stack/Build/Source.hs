{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TupleSections         #-}
-- Load information on package sources
module Stack.Build.Source
    ( loadSourceMap
    , SourceMap
    , PackageSource (..)
    , localFlags
    ) where

import Network.HTTP.Client.Conduit (HasHttpManager)
import           Control.Applicative          ((<|>), (<$>))
import           Control.Monad
import           Control.Monad.Catch          (MonadCatch)
import           Control.Monad.IO.Class
import           Control.Monad.Logger
import           Control.Monad.Reader         (MonadReader, asks)
import           Control.Monad.Trans.Resource
import           Data.Either
import qualified Data.Foldable                as F
import           Data.Function
import qualified Data.HashSet                 as HashSet
import           Data.List
import qualified Data.Map                     as Map
import           Data.Map.Strict              (Map)
import           Data.Maybe
import           Data.Monoid                  ((<>))
import           Data.Set                     (Set)
import qualified Data.Set                     as Set
import           Data.Text                    (Text)
import qualified Data.Text                    as T
import           Path
import           Prelude                      hiding (FilePath, writeFile)
import           Stack.Build.Cache
import           Stack.Build.Types
import           Stack.BuildPlan              (loadMiniBuildPlan,
                                               shadowMiniBuildPlan)
import           Stack.Constants              (wiredInPackages)
import           Stack.Package
import           Stack.PackageIndex
import           Stack.Types
import           System.Directory             hiding (findExecutable, findFiles)

type SourceMap = Map PackageName PackageSource
data PackageSource
    = PSLocal LocalPackage
    | PSUpstream Version Location (Map FlagName Bool)
    deriving Show
instance PackageInstallInfo PackageSource where
    piiVersion (PSLocal lp) = packageVersion $ lpPackage lp
    piiVersion (PSUpstream v _ _) = v

    piiLocation (PSLocal _) = Local
    piiLocation (PSUpstream _ loc _) = loc

loadSourceMap :: (MonadIO m, MonadCatch m, MonadReader env m, HasBuildConfig env, MonadBaseControl IO m, HasHttpManager env, MonadLogger m, HasEnvConfig env)
              => BuildOpts
              -> m ( MiniBuildPlan
                   , [LocalPackage]
                   , Set PackageName -- non-local targets
                   , SourceMap
                   )
loadSourceMap bopts = do
    bconfig <- asks getBuildConfig
    mbp0 <- case bcResolver bconfig of
        ResolverSnapshot snapName -> do
            $logDebug $ "Checking resolver: " <> renderSnapName snapName
            mbp <- loadMiniBuildPlan snapName
            return mbp
        ResolverGhc ghc -> return MiniBuildPlan
            { mbpGhcVersion = fromMajorVersion ghc
            , mbpPackages = Map.empty
            }

    menv <- getMinimalEnvOverride
    caches <- getPackageCaches menv
    let latestVersion = Map.fromList $ map toTuple $ Map.keys caches
    (locals, extraNames, extraIdents) <- loadLocals bopts latestVersion

    let nonLocalTargets = extraNames <> Set.map packageIdentifierName extraIdents

        -- Extend extra-deps to encompass targets requested on the command line
        -- that are not in the snapshot.
        extraDeps0 = extendExtraDeps
            (bcExtraDeps bconfig)
            mbp0
            latestVersion
            extraNames
            extraIdents

    let shadowed = Set.fromList (map (packageName . lpPackage) locals)
                <> Map.keysSet extraDeps0
        (mbp, extraDeps1) = shadowMiniBuildPlan mbp0 shadowed

        -- Add the extra deps from the stack.yaml file to the deps grabbed from
        -- the snapshot
        extraDeps2 = Map.union
            (Map.map (\v -> (v, Map.empty)) extraDeps0)
            (Map.map (\mpi -> (mpiVersion mpi, mpiFlags mpi)) extraDeps1)

        -- Overwrite any flag settings with those from the config file
        extraDeps3 = Map.mapWithKey
            (\n (v, f) -> PSUpstream v Local $ fromMaybe f $ Map.lookup n $ bcFlags bconfig)
            extraDeps2

    let sourceMap = Map.unions
            [ Map.fromList $ flip map locals $ \lp ->
                let p = lpPackage lp
                 in (packageName p, PSLocal lp)
            , extraDeps3
            , flip fmap (mbpPackages mbp) $ \mpi ->
                (PSUpstream (mpiVersion mpi) Snap (mpiFlags mpi))
            ] `Map.difference` Map.fromList (map (, ()) (HashSet.toList wiredInPackages))

    let unknown = Set.difference nonLocalTargets $ Map.keysSet sourceMap
    unless (Set.null unknown) $ do
        let toEither name =
                case Map.lookup name latestVersion of
                    Nothing -> Left name
                    Just version -> Right (name, version)
            eithers = map toEither $ Set.toList unknown
            (unknown', notInIndex) = partitionEithers eithers
        throwM $ UnknownTargets
            (Set.fromList unknown')
            (Map.fromList notInIndex)
            (bcStackYaml bconfig)

    return (mbp, locals, nonLocalTargets, sourceMap)

-- | Returns locals and extra target packages
loadLocals :: (MonadReader env m, HasBuildConfig env, MonadIO m, MonadLogger m, MonadThrow m, MonadCatch m,HasEnvConfig env)
           => BuildOpts
           -> Map PackageName Version
           -> m ([LocalPackage], Set PackageName, Set PackageIdentifier)
loadLocals bopts latestVersion = do
    targets <- mapM parseTarget $
        case boptsTargets bopts of
            [] -> ["."]
            x -> x
    (dirs, names, idents) <-
        case partitionEithers targets of
            ([], targets') -> return $ partitionTargetSpecs targets'
            (bad, _) -> throwM $ Couldn'tParseTargets bad

    econfig <- asks getEnvConfig
    bconfig <- asks getBuildConfig
    lps <- forM (Map.toList $ bcPackages bconfig) $ \(dir, validWanted) -> do
        cabalfp <- getCabalFileName dir
        name <- parsePackageNameFromFilePath cabalfp
        let wanted = validWanted && isWanted dirs names dir name
            config = PackageConfig
                { packageConfigEnableTests = False
                , packageConfigEnableBenchmarks = False
                , packageConfigFlags = localFlags (boptsFlags bopts) bconfig name
                , packageConfigGhcVersion = envConfigGhcVersion econfig
                , packageConfigPlatform = configPlatform $ getConfig bconfig
                }
            configFinal = config
                { packageConfigEnableTests = wanted && boptsFinalAction bopts == DoTests
                , packageConfigEnableBenchmarks = wanted && boptsFinalAction bopts == DoBenchmarks
                }
        pkg <- readPackage config cabalfp
        pkgFinal <- readPackage configFinal cabalfp
        when (packageName pkg /= name) $ throwM
            $ MismatchedCabalName cabalfp (packageName pkg)
        mbuildCache <- tryGetBuildCache dir
        fileModTimes <- getPackageFileModTimes pkg cabalfp
        return LocalPackage
            { lpPackage = pkg
            , lpPackageFinal = pkgFinal
            , lpWanted = wanted
            , lpDirtyFiles =
                  maybe True
                        ((/= fileModTimes) . buildCacheTimes)
                        mbuildCache
            , lpCabalFile = cabalfp
            , lpDir = dir
            , lpComponents = fromMaybe Set.empty $ Map.lookup name names
            }

    let known = Set.fromList $ map (packageName . lpPackage) lps
        unknown = Set.difference (Map.keysSet names) known

    return (lps, unknown, idents)
  where
    parseTarget t = do
        let s = T.unpack t
        isDir <- liftIO $ doesDirectoryExist s
        if isDir
            then liftM (Right . TSDir) $ liftIO (canonicalizePath s) >>= parseAbsDir
            else return
                    $ maybe (Left t) Right
                    $ (flip TSName Set.empty <$> parsePackageNameFromString s)
                  <|> (TSIdent <$> parsePackageIdentifierFromString s)
                  <|> (do
                        t' <- T.stripSuffix ":latest" t
                        name <- parsePackageNameFromString $ T.unpack t'
                        version <- Map.lookup name latestVersion
                        Just $ TSIdent $ PackageIdentifier name version)
                  <|> (do
                        let (name', rest) = T.break (== ':') t
                        component <- T.stripPrefix ":" rest
                        name <- parsePackageNameFromString $ T.unpack name'
                        Just $ TSName name $ Set.singleton component)
    isWanted dirs names dir name =
        name `Map.member` names ||
        any (`isParentOf` dir) dirs ||
        any (== dir) dirs

data TargetSpec
    = TSName PackageName (Set Text)
    | TSIdent PackageIdentifier
    | TSDir (Path Abs Dir)

partitionTargetSpecs :: [TargetSpec] -> ([Path Abs Dir], Map PackageName (Set Text), Set PackageIdentifier)
partitionTargetSpecs =
    loop id Map.empty Set.empty
  where
    loop dirs names idents ts0 =
        case ts0 of
            [] -> (dirs [], names, idents)
            TSName name comps:ts -> loop
                dirs
                (Map.insertWith Set.union name comps names)
                idents
                ts
            TSIdent ident:ts -> loop dirs names (Set.insert ident idents) ts
            TSDir dir:ts -> loop (dirs . (dir:)) names idents ts

-- | All flags for a local package
localFlags :: (Map PackageName (Map FlagName Bool))
           -> BuildConfig
           -> PackageName
           -> Map FlagName Bool
localFlags boptsflags bconfig name = Map.union
    (fromMaybe Map.empty $ Map.lookup name $ boptsflags)
    (fromMaybe Map.empty $ Map.lookup name $ bcFlags bconfig)

-- | Add in necessary packages to extra dependencies
--
-- See https://github.com/commercialhaskell/stack/issues/272 for the requirements of this function
extendExtraDeps :: Map PackageName Version -- ^ original extra deps
                -> MiniBuildPlan
                -> Map PackageName Version -- ^ latest versions in indices
                -> Set PackageName -- ^ extra package names desired
                -> Set PackageIdentifier -- ^ extra package identifiers desired
                -> Map PackageName Version -- ^ new extradeps
extendExtraDeps extraDeps0 mbp latestVersion extraNames extraIdents =
    F.foldl' addIdent
        (F.foldl' addName extraDeps0 extraNames)
        extraIdents
  where
    snapshot = fmap mpiVersion $ mbpPackages mbp

    addName m name =
        case Map.lookup name m <|> Map.lookup name snapshot of
            -- alright exists in snapshot or extra-deps
            Just _ -> m
            Nothing ->
                case Map.lookup name latestVersion of
                    -- use the latest version in the index
                    Just v -> Map.insert name v m
                    -- does not exist, will be reported as an error
                    Nothing -> m

    addIdent m (PackageIdentifier name version) =
        case Map.lookup name snapshot of
            -- the version matches what's in the snapshot, so just use the snapshot version
            Just version' | version == version' -> m
            _ -> Map.insert name version m
