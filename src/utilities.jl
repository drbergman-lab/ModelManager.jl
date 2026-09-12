"""
    quietRun(cmd::Cmd)

Run the command with stdout and stderr redirected to devnull so no output goes to the console.
"""
quietRun(cmd::Cmd) = run(pipeline(cmd, stdout=devnull, stderr=devnull))

#! Public despite not being exported: a simulator backend probing for its own executables wants
#! exactly this, and PhysiCellModelManager had copied the one-liner verbatim rather than reach for
#! an internal. See CLAUDE.md, "Docstring cross-references".
@compat public quietRun