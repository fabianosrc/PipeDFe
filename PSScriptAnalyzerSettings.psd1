@{
    Severity = @('Error', 'Warning')

    IncludeRules = @(
        # Security
        'PSAvoidUsingInvokeExpression'
        'PSAvoidUsingPlainTextForPassword'
        'PSAvoidUsingConvertToSecureStringWithPlainText'
        'PSAvoidUsingComputerNameHardcoded'

        # Best practices
        'PSAvoidUsingCmdletAliases'
        'PSAvoidUsingPositionalParameters'
        'PSAvoidUsingWriteHost'
        'PSAvoidDefaultValueSwitchParameter'
        'PSAvoidGlobalVars'

        # Cmdlet / function design
        'PSUseApprovedVerbs'
        'PSUseSingularNouns'
        'PSUseShouldProcessForStateChangingFunctions'
        'PSUsePSCredentialType'
        'PSUseProcessBlockForPipelineCommand'

        # Type safety / correctness
        'PSUseOutputTypeCorrectly'
        'PSUseDeclaredVarsMoreThanAssignments'
        'PSUseCmdletCorrectly'

        # Compatibility
        'PSUseCompatibleSyntax'

        # Documentation
        'PSProvideCommentHelp'

        # Code quality
        'PSReviewUnusedParameter'
        'PSMisleadingBacktick'
        'PSAvoidUsingEmptyCatchBlock'

        # Formatting / style
        'PSUseConsistentIndentation'
        'PSUseConsistentWhitespace'
        'PSAvoidTrailingWhitespace'
        'PSAvoidMultipleEmptyLines'
        'PSAvoidMultipleStatementsPerLine'
        'PSPipelineIndentation'
        'PSUseCorrectCasing'
        'PSHashTableFormatting'

        # Misc
        'PSReservedCmdletChar'
        'PSReservedParams'
        'PSMissingModuleManifestField'
    )

    Rules = @{
        # Windows PowerShell 5.1 is the compatibility baseline
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('5.1')
        }

        PSUseCompatibleTypes = @{
            Enable         = $true
            TargetVersions = @('5.1')
        }

        PSUseCompatibleCommands = @{
            Enable         = $true
            TargetVersions = @('5.1')
        }

        # Public functions must have comment-based help
        PSProvideCommentHelp = @{
            Enable                  = $true
            ExportedOnly            = $true
            BlockComment            = $true
            VSCodeSnippetCorrection = $false
            Placement               = 'before'
        }

        # OTBS style with 4 spaces
        PSUseConsistentIndentation = @{
            Enable          = $true
            IndentationSize = 4
        }

        # Pipeline indentation
        PSPipelineIndentation = @{
            Enable           = $true
            IndentationStyle = 'IncreaseForFirstPipeline'
        }

        # Hashtable alignment
        PSHashTableFormatting = @{
            Enable             = $true
            AlignKeysAndValues = $true
            IndentationSize    = 4
        }
    }
}
