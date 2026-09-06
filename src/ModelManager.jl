module ModelManager

using Compat
using Parameters
using Random
using Statistics
using NearestNeighbors
using QuasiMonteCarlo
using Sobol

export AbstractSimulator, postInitDisplay, centralDBFileName
export getInstalledVersion, getDBPackageVersion, resolvePackageVersion
export queryToDataFrame, stmtToDataFrame, constructSelectQuery, tableIDName
export tableExists, tableColumns
export locationVariationsDatabase
export ModelManagerGlobals, mm_globals, assertInitialized
export centralDB, dataDir, isInitialized, projectLocations, inputsDict
export withTransaction
export initializeModelManager
export setNumberOfParallelSims
export isRunningOnHPC, useHPC, setJobOptions, setHPCCompletionOptions, rm_hpc_safe
export ProjectLocations, parseProjectInputsConfigurationFile
export locationIDName, locationVariationIDName, locationTableName, locationFolder
export locationVariationsTableName, locationVariationsFolder, locationVariationsDBName
export locationPath, folderIsVaried, pathToInputsConfig
export locationIDNames, locationVariationIDNames
export InputFolder, InputFolders, VariationID
export AbstractTrial, AbstractSampling, AbstractMonad
export Simulation, Monad, Sampling, Trial
export constituentIDs, simulationIDs, monadIDs, trialFolder, pathToOutputFolder
export MMOutput, trialID, trialType
export simulationID, monadID, wasSuccessful
export createMMTable, insertFolder
export deleteSimulation, deleteSimulations, deleteAllSimulations, deleteSimulationsByStatus
export deleteMonad, deleteSampling, deleteTrial, deleteCalibration, resetDatabase
export run
export printSimulationIDs
export shortLocationVariationID
export simulationsTable, printSimulationsTable
export monadsTable, printMonadsTable
export calibrationsTable, printCalibrationsTable
export postProcessingTable, printPostProcessingTable, postProcessingDBPath
export tag!, untag!, tags, hasTag
export findTrials, findSimulations, findSimulationIDs, findMonads
export tagsTable, printTagsTable, tagKeys, tagValues, recommendedTagKeys
export setTagHints!, gitState, appendTags!, orphanedTagCounts
export simulationsFromIDs
export XMLPath
export AbstractVariation, ElementaryVariation, DiscreteVariation, DistributedVariation, CoVariation, LatentVariation
export UniformDistributedVariation, NormalDistributedVariation
export GridVariation, LHSVariation, SobolVariation, RBDVariation
export AddGridVariationsResult, AddLHSVariationsResult, AddSobolVariationsResult, AddRBDVariationsResult
export columnName, calculateGSA!
export sqliteDataType
export MOAT, Sobolʼ, SobolMM, RBD
export createTrial
export getSimpleContent, retrieveElement, columnNameToXMLPath
export parseValueFromString, getParameterValue, getAllParameterValues
export AbstractCalibrationMethod, ABCSMC, runCalibration
export GaussianKernel, ComponentwiseKernel, LocalNNKernel, LocalNNCovKernel
export CalibrationProblem, Calibration, GenerationResult, ABCResult, posterior
export ConvergenceSummary
export mseDistance
export runABC, resumeABC, resumeCalibration

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
include("hpc_completion.jl")
include("runner.jl")
include("deletion.jl")
include("xml_utilities.jl")
include("variations.jl")
include("study.jl")
include("qoi.jl")
include("sensitivity.jl")
include("sensitivity_visualize.jl")
include("user_api.jl")
include("calibration/calibration.jl")
include("calibration/visualize.jl")
#! `tags.jl` is included last so its methods can dispatch on any type in the package: a method
#! signature is evaluated when the method is defined, so a tagging method for a type declared in a
#! later file would be an `UndefVarError`. Keep it last when adding a new include. Nothing loaded
#! before it needs its names at load time — every call into tagging from an earlier file is inside a
#! function body, which Julia resolves lazily.
include("tags.jl")

end
