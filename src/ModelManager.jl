module ModelManager

using Compat
using Parameters
using Random
using Statistics
using QuasiMonteCarlo
import QuasiMonteCarlo: randomize, NoRand, RandomizationMethod
using Sobol

export AbstractSimulator
export continueMilestoneUpgrade, populateTableOnFeatureSubset, upgradePackage
export getPackageVersion, getDBPackageVersion, resolvePackageVersion
export queryToDataFrame, stmtToDataFrame, constructSelectQuery, tableIDName
export tableExists, tableColumns, columnsExist, buildWhereClause
export statusCodeID, isStarted, locationVariationsDatabase
export databaseDiagnostics, variationIDs
export ModelManagerGlobals, mm_globals_ref, mm_globals, assertInitialized
export centralDB, dataDir, isInitialized, projectLocations, inputsDict
export simulatorVersionIDName, currentSimulatorVersionID
export initializeModelManager
export setNumberOfParallelSims
export isRunningOnHPC, prepareHPCCommand, useHPC, setJobOptions, rm_hpc_safe
export ProjectLocations, parseProjectInputsConfigurationFile, sanitizePathElement
export locationIDName, locationVariationIDName, locationTableName, locationFolder
export locationVariationsTableName, locationVariationsFolder, locationVariationsDBName
export locationPath, folderIsVaried, pathToInputsConfig
export locationIDNames, locationVariationIDNames
export InputFolder, InputFolders, VariationID
export AbstractTrial, AbstractSampling, AbstractMonad
export Simulation, Monad, Sampling, Trial
export constituentIDs, simulationIDs, monadIDs, trialFolder, pathToOutputFolder
export lowerClassString, constituentType, constituentTypeFilename
export MMOutput, trialID, trialType
export recordConstituentIDs, compressIDs
export createMMTable, createPCMMTable
export initializeDatabase, createSchema, insertFolder
export inputFolderName, inputFolderID
export deleteSimulation, deleteSimulations, deleteSimulationsByStatus, resetDatabase
export deleteMonad, deleteSampling, deleteTrial
export eraseSimulationIDFromConstituents
export SimulationProcess, updateDatabaseOnCompletion, simulationFailed
export dispatchSimulation, runAbstractTrial, run
export reinitializeDatabase, addFolderNameColumns!, printSimulationIDs
export shortLocationVariationID, shortVariationName
export locationVariationsTable, appendVariations
export simulationsTableFromQuery, simulationsTable, printSimulationsTable
export XMLPath
export AbstractVariation, ElementaryVariation, DiscreteVariation, DistributedVariation, CoVariation, LatentVariation
export UniformDistributedVariation, NormalDistributedVariation
export AddVariationMethod, GridVariation, LHSVariation, SobolVariation, RBDVariation
export AddVariationsResult, AddGridVariationsResult, AddLHSVariationsResult, AddSobolVariationsResult, AddRBDVariationsResult
export ParsedVariations
export addVariations, columnName, calculateGSA!
export variationLocation, variationValues, variationTarget, variationDataType, sqliteDataType, nTargetDims
export MOAT, Sobolʼ, SobolMM, RBD
export GSAMethod, GSASampling, MOATSampling, SobolSampling, RBDSampling
export createTrial

include("utilities.jl")
include("abstract_simulator.jl")
include("up.jl")
include("package_version.jl")
include("hpc.jl")
include("project_configuration.jl")
include("globals.jl")
include("classes.jl")
include("recorder.jl")
include("database.jl")
include("runner.jl")
include("deletion.jl")
include("variations.jl")
include("sensitivity.jl")
include("user_api.jl")

end
