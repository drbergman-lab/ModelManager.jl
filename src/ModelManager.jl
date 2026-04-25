module ModelManager

using Compat
using Parameters
using Random
using Statistics
using QuasiMonteCarlo
using Sobol

export AbstractSimulator
export getPackageVersion, getDBPackageVersion, resolvePackageVersion
export queryToDataFrame, stmtToDataFrame, constructSelectQuery, tableIDName
export tableExists, tableColumns
export locationVariationsDatabase
export ModelManagerGlobals, mm_globals_ref, mm_globals, assertInitialized
export centralDB, dataDir, isInitialized, projectLocations, inputsDict
export initializeModelManager
export setNumberOfParallelSims
export isRunningOnHPC, useHPC, setJobOptions, rm_hpc_safe
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
export createMMTable, insertFolder
export deleteSimulation, deleteSimulations, deleteSimulationsByStatus, resetDatabase
export run
export printSimulationIDs
export shortLocationVariationID
export simulationsTable, printSimulationsTable
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
export CalibrationParameter, CalibrationProblem, Calibration, GenerationResult, ABCResult, posterior
export mseDistance
export runABC, resumeABC
export createCalibration, calibrationFolder, calibrationMonadsCSV, calibrationMonadIDs
export calibrationsSchema

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
include("xml_utilities.jl")
include("variations.jl")
include("sensitivity.jl")
include("user_api.jl")
include("calibration/calibration.jl")

end
