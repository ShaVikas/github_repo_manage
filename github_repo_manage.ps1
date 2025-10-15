# Requires -Version 5.1

# ==============================================================================
# CONFIGURATION VARIABLES
# ==============================================================================
# Maximum number of files and folders to display in the interactive directory prompt.
$MaxDisplayItems = 15

<#
.SYNOPSIS
Advanced interactive script for syncing and managing GitHub repositories using the GitHub CLI (gh).

.DESCRIPTION
This script provides an interactive menu with features for:
1. Discovering remote repositories (using 'gh repo list').
2. Comparing remote vs. local copies to identify new repositories to clone.
3. Bulk updating (pulling) all existing local Git repositories.
4. Robust error handling with continuation and a post-operation retry/skip mechanism for failed repositories.

.NOTES
Requires the GitHub CLI (gh) and Git. Run 'gh auth login' before use.
The script uses 'gh repo list' to determine available remote repositories.
#>

# ==============================================================================
# 1. CORE EXECUTION AND ERROR HANDLING FUNCTION
# ==============================================================================

function Execute-Command {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Command,

        [Parameter(Mandatory=$true)]
        [string[]]$Arguments, # Now accepts an array of strings for clean argument passing

        [string]$WorkingDirectory,

        [string]$RepoIdentifier = "N/A"
    )

    # Display command execution clearly
    Write-Host "Executing: ${Command} $($Arguments -join ' ') in ${WorkingDirectory}" -ForegroundColor Cyan

    $ResultObject = [PSCustomObject]@{
        Success        = $false
        Output         = ""
        ExitCode       = 1
        RepoIdentifier = $RepoIdentifier
        Command        = $Command
        Arguments      = $Arguments # Store arguments as array
        WorkingDirectory = $WorkingDirectory
    }

    try {
        # FIX: Explicitly set the working directory for the external command by changing the location.
        Push-Location $WorkingDirectory -ErrorAction Stop

        # Execute the external command, spreading the arguments array ($Arguments)
        $Result = & $Command $Arguments 2>&1
        $ResultObject.Output = $Result -join "`n"
        $ResultObject.ExitCode = $LASTEXITCODE
        
        # Check if the command execution resulted in errors
        if ($LASTEXITCODE -eq 0) {
            $ResultObject.Success = $true
            Write-Host "Success: ${RepoIdentifier} updated." -ForegroundColor Green
        } else {
            Write-Host "Error executing ${Command}. Exit Code: ${LASTEXITCODE}" -ForegroundColor Red
            $Result | Write-Host -ForegroundColor Red
        }

    } catch {
        # Catch errors from the command execution or from Push-Location
        $ResultObject.Output = "An exception occurred: $($_.Exception.Message)"
        Write-Host "Exception during execution: ${Command}: $($_.Exception.Message)" -ForegroundColor Red 
    } finally {
        # Ensure the original location is restored, even if an error occurred.
        Pop-Location -ErrorAction SilentlyContinue
    }

    return $ResultObject
}

# ==============================================================================
# 2. PREREQUISITE AND DISCOVERY FUNCTIONS
# ==============================================================================

function Check-Prerequisites {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        Write-Host "ERROR: GitHub CLI ('gh') is required. Please install it." -ForegroundColor Red
        return $false
    }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Host "ERROR: Git ('git') is required. Please install it." -ForegroundColor Red
        return $false
    }
    return $true
}

function Get-AuthenticatedUser {
    # Tries to get the login of the currently authenticated GitHub user.
    try {
        # Use 'gh api user' to get user details and jq to extract the login. Suppress stderr.
        $user = & gh api user --jq .login 2>$null
        
        if ($user -is [string] -and -not [string]::IsNullOrWhiteSpace($user)) {
            return $user.Trim()
        }
    } catch {
        # Silent failure if 'gh' is not authenticated or API call fails
    }
    return $null
}

function Get-LinkedOrganizations {
    # Tries to get the list of organizations the authenticated user is a member of.
    try {
        # Using the /user/orgs endpoint and jq to extract the login names
        $orgs = & gh api user/orgs --jq '.[] | .login' 2>$null
        
        if ($orgs -is [array] -and $orgs.Count -gt 0) {
            return $orgs
        }
    } catch {
        # Silent failure if the API call fails or user is not logged in
    }
    return @()
}

function Get-RemoteRepositories {
    param(
        [string]$FilterUser
    )

    Write-Host "`nFetching list of repositories for user/org: '${FilterUser}'..." -ForegroundColor Yellow
    
    try {
        # FIX: The previous method of calling gh with arguments concatenated on one line sometimes
        # causes tokenization errors (e.g., 'accepts at most 1 arg(s), received 2').
        # We now use an explicit argument array, which is the most reliable way to pass
        # arguments to external commands in PowerShell.
        
        $Arguments = @(
            "repo", 
            "list", 
            $FilterUser, 
            "--json", "nameWithOwner", 
            "--limit", "100", 
            "--jq", ".[].nameWithOwner"
        )
        
        # Execute 'gh' with the clean argument array
        # Suppress standard error (2>$null) to prevent gh output from appearing as errors
        $repos = & gh $Arguments 2>$null
        
        Write-Host "Found $($repos.Count) remote repositories." -ForegroundColor DarkGreen
        return $repos
    } catch {
        Write-Host "ERROR: Failed to retrieve remote repositories. Ensure you are logged in ('gh auth login'). Error: $($_.Exception.Message)" -ForegroundColor Red
        return @()
    }
}

function Get-LocalRepositories {
    param(
        [string]$StartDirectory
    )

    if (-not (Test-Path $StartDirectory -PathType Container)) {
        Write-Host "Error: Directory '${StartDirectory}' not found." -ForegroundColor Red
        return @()
    }

    Write-Host "Searching for local Git repositories under ${StartDirectory}..." -ForegroundColor DarkGray
    
    # FIX: Modified the logic to explicitly check only direct subdirectories (Depth 1) 
    # for a .git folder. This avoids issues with Get-ChildItem -Recurse sometimes missing
    # immediate children that are expected to be the repos, which was causing the 
    # "Found 0 local repository folders" error for the PULL ALL operation.
    $LocalRepos = Get-ChildItem -Path $StartDirectory -Directory -Depth 1 -ErrorAction SilentlyContinue | Where-Object {
        # Check if the subfolder contains a .git subdirectory
        (Test-Path -Path (Join-Path -Path $_.FullName -ChildPath ".git") -PathType Container)
    } | Select-Object -Property @{N='Name'; E={$_.Name}}, @{N='Path'; E={$_.FullName}}
    
    Write-Host "Found $($LocalRepos.Count) local repository folders (with a .git directory)." -ForegroundColor DarkGreen
    return $LocalRepos
}

# ==============================================================================
# 3. INTERACTIVE DIRECTORY NAVIGATION
# ==============================================================================

function Get-InteractiveDirectory {
    param(
        [string]$PromptMessage
    )

    $currentPath = (Get-Location).Path
    $ConfirmedPath = $null
    
    do {
        Clear-Host
        Write-Host "--- Directory Navigator ---" -ForegroundColor White
        Write-Host "$PromptMessage" -ForegroundColor Yellow
        Write-Host " "

        # Display Current Path
        Write-Host "Current Path: " -NoNewline -ForegroundColor White
        Write-Host "$currentPath" -ForegroundColor Cyan
        Write-Host "--------------------------------------------------------" -ForegroundColor DarkGray

        # List contents
        $contents = Get-ChildItem -Path $currentPath -ErrorAction SilentlyContinue | Sort-Object -Property PSIsContainer, Name
        $displayContents = $contents | Select-Object -First $MaxDisplayItems
        $totalItems = $contents.Count
        
        # Display special navigation options
        Write-Host " "
        Write-Host "   [..] - Parent Folder" -ForegroundColor Green
        Write-Host " "

        # Display items
        if ($displayContents.Count -gt 0) {
            Write-Host "Contents (Showing $($displayContents.Count) of $totalItems):" -ForegroundColor DarkGray
            foreach ($item in $displayContents) {
                $type = if ($item.PSIsContainer) {'[D]'} else {'[F]'}
                $color = if ($item.PSIsContainer) { "White" } else { "DarkGray" }
                Write-Host "   $type $($item.Name)" -ForegroundColor $color
            }
        } else {
            Write-Host "   (Folder is empty or contents exceed $MaxDisplayItems limit.)" -ForegroundColor DarkGray
        }

        Write-Host "--------------------------------------------------------" -ForegroundColor DarkGray
        
        # === User Requested Prompt ===
        $inputPath = Read-Host "Enter Folder Name/Path (or C to Confirm Folder, M to Menu):"
        
        if ([string]::IsNullOrWhiteSpace($inputPath) -or $inputPath.ToUpper() -eq 'C') {
            # User confirmed the current path
            $ConfirmedPath = $currentPath
            break
        }
        
        # Handle M (Menu) as cancellation
        if ($inputPath.ToUpper() -eq 'M') {
            # User cancelled
            return $null
        }

        # === LOGIC FOR FOLDER CREATION AND NAVIGATION ===
        try {
            # 1. Determine the full path the user is trying to reach
            $proposedNewPath = Join-Path -Path $currentPath -ChildPath $inputPath
            
            if (Test-Path $proposedNewPath -PathType Container) {
                # Path exists and is a container: navigate into it
                $currentPath = (Resolve-Path $proposedNewPath).Path
            } elseif (Test-Path $proposedNewPath -PathType Leaf) {
                # Path exists but is a file: error
                Write-Host "Error: '$inputPath' is a file, not a directory." -ForegroundColor Red
            } else {
                # Path does not exist: prompt for creation
                Write-Host "The folder '$inputPath' was not found." -ForegroundColor Yellow
                $createConfirm = Read-Host "Do you want to create this folder? (Y/N)"
                
                if ($createConfirm.ToUpper() -eq 'Y') {
                    try {
                        New-Item -Path $proposedNewPath -ItemType Directory -Force | Out-Null
                        $currentPath = $proposedNewPath
                        Write-Host "Folder '$inputPath' created and navigated to." -ForegroundColor Green
                    } catch {
                        Write-Host "Error creating folder: $($_.Exception.Message)" -ForegroundColor Red
                    }
                } else {
                    Write-Host "Creation skipped. Staying in current path." -ForegroundColor DarkGray
                }
            }
        } catch {
            # Catch all for unexpected errors 
            Write-Host "An unexpected error occurred while processing the path: $($_.Exception.Message)" -ForegroundColor Red
        }

    } while ($true)

    return $ConfirmedPath
}

# ==============================================================================
# 4. RETRY LOGIC FUNCTION
# ==============================================================================

function Retry-FailedOperations {
    param(
        [Parameter(Mandatory=$true)]
        [ValidateScript({$_.Count -ge 0})]
        [PSCustomObject[]]$FailedOperations
    )

    if ($FailedOperations.Count -eq 0) {
        Write-Host "All operations completed successfully." -ForegroundColor Green
        return
    }

    $CurrentFailures = $FailedOperations | Select-Object *
    $NewFailures = @()
    
    do {
        Write-Host "`n--- FAILED OPERATIONS (${CurrentFailures.Count} Repos) ---" -ForegroundColor Red
        Write-Host "The following repositories failed in the last action:" -ForegroundColor Yellow

        $i = 1
        foreach ($f in $CurrentFailures) {
            # Display the command using -join to show the array elements separated by spaces
            Write-Host "${i}. ${f.RepoIdentifier} (`$${f.Command} $($f.Arguments -join ' ') in ${f.WorkingDirectory})" -ForegroundColor DarkRed
            $i++
        }
        
        Write-Host "`nOptions:" -ForegroundColor White
        Write-Host "  R: Retry ALL failed operations." -ForegroundColor Green
        Write-Host "  S: Skip ALL and return to the main menu." -ForegroundColor Yellow
        
        $Action = Read-Host "Select R or S"
        $Action = $Action.ToUpper()
        
        if ($Action -eq 'R') {
            Write-Host "`nAttempting to retry ${CurrentFailures.Count} failed operations..." -ForegroundColor Magenta
            $NewFailures = @() # Reset failures for the retry attempt

            foreach ($f in $CurrentFailures) {
                Write-Host "`n-> Retrying ${f.RepoIdentifier}..." -ForegroundColor Yellow
                
                # Execute the failed command again, passing the Arguments array
                $Result = Execute-Command -Command $f.Command -Arguments $f.Arguments -WorkingDirectory $f.WorkingDirectory -RepoIdentifier $f.RepoIdentifier
                
                # If retry failed, add it to the new failures list
                if (-not $Result.Success) {
                    # NOTE: $Result.Arguments already contains the array passed to Execute-Command
                    $NewFailures += $Result
                }
            }

            $CurrentFailures = $NewFailures
            if ($CurrentFailures.Count -eq 0) {
                Write-Host "`nAll retries successful!" -ForegroundColor Green
                break # Exit the loop
            }

        } elseif ($Action -eq 'S') {
            Write-Host "`nSkipping remaining failed operations." -ForegroundColor Yellow
            break # Exit the loop
        } else {
            Write-Host "Invalid option. Please enter R or S." -ForegroundColor Red
        }

    } while ($CurrentFailures.Count -gt 0)

    Write-Host "Finished processing failed operations." -ForegroundColor White
}

# ==============================================================================
# 5. MAIN WORKFLOWS
# ==============================================================================

function Clone-NewRepositories {
    Write-Host "`n--- Discover & Clone Missing Repositories ---" -ForegroundColor Yellow
    
    $SelectedRepoUser = $null
    
    # 1. Authentication Check and User/Org Selection Loop
    while ($null -eq $SelectedRepoUser) {
        
        # Check authentication status
        $AuthenticatedUser = Get-AuthenticatedUser
        
        if (-not $AuthenticatedUser) {
            Write-Host "`n! ERROR: GitHub CLI is not authenticated." -ForegroundColor Red
            Write-Host "Please run 'gh auth login' in a separate console window to authenticate." -ForegroundColor Yellow
            $Action = Read-Host "Press 'R' to check authentication status again, or 'M' to return to the main menu."
            
            if ($Action.ToUpper() -eq 'M') { return }
            
            # Loop continues if 'R' is pressed or any other key
            continue
        }
        
        # If authenticated, proceed to build the selection menu
        
        Write-Host "`nSuccessfully authenticated as: ${AuthenticatedUser}" -ForegroundColor Green
        
        $LinkedOrganizations = Get-LinkedOrganizations
        
        Write-Host "`nSelect the GitHub User/Organization for synchronization:" -ForegroundColor White
        
        $Options = @{}
        $OptionIndex = 1
        
        # Option 1: Authenticated User
        Write-Host "${OptionIndex}: Authenticated User (${AuthenticatedUser})" -ForegroundColor Green
        $Options.Add($OptionIndex.ToString(), $AuthenticatedUser)
        $OptionIndex++

        # Options 2+: Linked Organizations
        if ($LinkedOrganizations.Count -gt 0) {
            Write-Host "`n--- Linked Organizations ---" -ForegroundColor DarkYellow
            foreach ($Org in $LinkedOrganizations) {
                Write-Host "${OptionIndex}: Organization (${Org})" -ForegroundColor DarkYellow
                $Options.Add($OptionIndex.ToString(), $Org)
                $OptionIndex++
            }
        }
        
        # Option M: Manual Entry
        Write-Host "`nM: Manually enter a username or organization name" -ForegroundColor Yellow
        
        $Choice = Read-Host "Enter your selection (1, 2, ..., or M for Manual Entry)"
        $Choice = $Choice.ToUpper()
        
        if ($Choice -eq 'M') {
            $SelectedRepoUser = Read-Host "Enter the target username or organization name"
        } elseif ($Options.ContainsKey($Choice)) {
            $SelectedRepoUser = $Options[$Choice]
        } else {
            Write-Host "Invalid choice. Please try again." -ForegroundColor Red
            Start-Sleep -Seconds 1
            continue
        }
        
        # Final validation after selection
        if ([string]::IsNullOrWhiteSpace($SelectedRepoUser)) {
            Write-Host "The username/organization name cannot be empty. Please try again." -ForegroundColor Red
            $SelectedRepoUser = $null # Force loop continuation
        }
    }
    
    $RepoUser = $SelectedRepoUser # Set the main variable

    # Use the new interactive directory function
    $StartDirectory = Get-InteractiveDirectory -PromptMessage "Select the local folder where new repositories should be cloned."
    
    if ($null -eq $StartDirectory) {
        Write-Host "Operation cancelled." -ForegroundColor Yellow
        return
    }

    # If the directory doesn't exist, create it.
    if (-not (Test-Path $StartDirectory -PathType Container)) {
         Write-Host "Creating local directory: $StartDirectory" -ForegroundColor DarkYellow
         New-Item -Path $StartDirectory -ItemType Directory -Force | Out-Null
    }

    # 2. Discovery
    $RemoteRepos = Get-RemoteRepositories -FilterUser $RepoUser
    # NOTE: Get-LocalRepositories is not strictly needed for the comparison filter,
    # but we run it for the useful troubleshooting output.
    $LocalRepos  = Get-LocalRepositories -StartDirectory $StartDirectory
    
    if (-not $RemoteRepos) { return }

    # --- START OF FIX: Use simple folder existence check to prevent gh clone error ---
    
    # 2b. Get ALL top-level folder names in the target directory (Case-Insensitive)
    # This prevents the "directory already exists" error from gh clone, even if the folder lacks a .git
    $ExistingFolderNames = Get-ChildItem -Path $StartDirectory -Directory -Depth 0 -ErrorAction SilentlyContinue |
                           Select-Object -ExpandProperty Name |
                           ForEach-Object { $_.ToLower() }
    
    # 3. Comparison (Find Remote repos where the folder name does not exist locally)
    $ReposToClone = @()
    $ReposSkipped = 0 # Counter for repos skipped due to existing folders

    foreach ($RemoteRepo in $RemoteRepos) {
        # Extract the repository folder name
        $RepoFolderName = $RemoteRepo.Split('/')[-1]
        $LowerCaseRepoFolderName = $RepoFolderName.ToLower()
        
        # Check if a folder with this name already exists locally (case-insensitively)
        if ($ExistingFolderNames -contains $LowerCaseRepoFolderName) {
            # This is the fix: Skip if the folder exists, preventing the gh clone error
            Write-Host "NOTE: Automatically skipping '${RepoFolderName}'. A folder with this name already exists in '$StartDirectory', which would cause the 'gh clone' command to fail." -ForegroundColor DarkGray
            $ReposSkipped++
            continue 
        }
        
        # Only add to the list if the folder does not exist at all
        $ReposToClone += [PSCustomObject]@{
            Repo = $RemoteRepo
            Name = $RepoFolderName
        }
    }
    # --- END OF FIX ---
    
    # NEW: Add troubleshooting hint if local repos found is low
    if ($LocalRepos.Count -lt 5 -and $RemoteRepos.Count -gt 5) {
        Write-Host "`n(TROUBLESHOOTING TIP): The script only found $($LocalRepos.Count) local Git repos in '$($StartDirectory)'. If this number seems too low, you may have selected the wrong parent directory, or your existing clones are not in a valid Git state (missing the .git folder)." -ForegroundColor DarkYellow
    }

    if ($ReposSkipped -gt 0) {
        Write-Host "`n(${ReposSkipped}) repos were skipped because a local folder with the same name was found." -ForegroundColor DarkYellow
    }

    if ($ReposToClone.Count -eq 0) {
        Write-Host "`nNo new repositories found to clone. All remote repos seem to be present locally." -ForegroundColor Green
        return
    }

    # --- START REPO SELECTION LOGIC (New Step 4) ---
    $SelectedRepos = @()
    
    do {
        Clear-Host
        Write-Host "--- Repository Selection ---" -ForegroundColor White
        Write-Host "Found $($ReposToClone.Count) remote repositories not cloned locally." -ForegroundColor Yellow
        Write-Host " "

        # Display list with index
        Write-Host "Available Repositories:" -ForegroundColor White
        $index = 1
        foreach ($Repo in $ReposToClone) {
            # Temporarily add index for selection mapping
            $Repo | Add-Member -MemberType NoteProperty -Name Index -Value $index -Force
            Write-Host "  $($index.ToString().PadLeft(3)): $($Repo.Repo)" -ForegroundColor DarkGreen
            $index++
        }
        
        Write-Host "--------------------------------------------------------" -ForegroundColor DarkGray
        Write-Host "Enter your selection using numbers, ranges, or keywords." -ForegroundColor White
        Write-Host "Examples: '1,3,5' | '1-10' | 'A' (All)" -ForegroundColor Yellow
        Write-Host "  A: Select All Repositories" -ForegroundColor Green
        Write-Host "  Q: Cancel and return to menu" -ForegroundColor Red
        
        $SelectionInput = Read-Host "Enter selection (1, 2, 1-5, A, or Q):"
        $SelectionInput = $SelectionInput.Trim()
        
        # Handle Cancel
        if ([string]::IsNullOrWhiteSpace($SelectionInput) -or $SelectionInput.ToUpper() -eq 'Q') {
            Write-Host "Clone operation cancelled." -ForegroundColor Yellow
            return
        }

        # Handle Select All
        if ($SelectionInput.ToUpper() -eq 'A') {
            $SelectedRepos = $ReposToClone
            break
        }
        
        # Handle custom selection (numbers/ranges)
        $SelectionIndices = @()
        $parts = $SelectionInput.Split(',')
        
        foreach ($part in $parts) {
            $p = $part.Trim()
            if ($p -match '^\d+-\d+$') {
                # Handle range (e.g., 1-5)
                try {
                    $rangeStart = [int]($p -split '-')[0]
                    $rangeEnd = [int]($p -split '-')[1]
                    for ($i = $rangeStart; $i -le $rangeEnd; $i++) {
                        if ($i -ge 1 -and $i -le $ReposToClone.Count) {
                            $SelectionIndices += $i
                        }
                    }
                } catch {
                    Write-Host "Invalid range format: '$p'. Skipping." -ForegroundColor Red
                }
            } elseif ($p -match '^\d+$') {
                # Handle single number (e.g., 3)
                $i = [int]$p
                if ($i -ge 1 -and $i -le $ReposToClone.Count) {
                    $SelectionIndices += $i
                } else {
                    Write-Host "Invalid number '$i': Must be between 1 and $($ReposToClone.Count). Skipping." -ForegroundColor Red
                }
            } else {
                Write-Host "Invalid format: '$p'. Please use numbers, commas, or ranges (e.g., 1,3, 5-8). Skipping." -ForegroundColor Red
            }
        }
        
        # Remove duplicates and map indices to repo objects
        $UniqueIndices = $SelectionIndices | Select-Object -Unique | Sort-Object
        $SelectedRepos = $ReposToClone | Where-Object { $UniqueIndices -contains $_.Index }
        
        if ($SelectedRepos.Count -gt 0) {
            break # Exit the selection loop
        }
        
        Write-Host "No valid repositories selected. Press any key to try again." -ForegroundColor DarkGray
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")

    } while ($true)
    
    # 5. Confirmation before cloning
    Write-Host "`nYou have selected $($SelectedRepos.Count) repositories to clone:" -ForegroundColor Yellow
    $SelectedRepos | Select-Object -Property Repo | Format-Table
    
    $FinalConfirm = Read-Host "Confirm cloning the selected repos? (Y/N)"
    if ($FinalConfirm -ne 'Y') {
        Write-Host "Clone operation cancelled." -ForegroundColor Yellow
        return
    }

    # 6. Execution (Cloning)
    $FailedClones = @()
    foreach ($Repo in $SelectedRepos) {
        Write-Host "`n-> Cloning ${Repo.Repo}..." -ForegroundColor Yellow
        
        # NEW: Arguments are passed as an array of strings
        # Note: 'gh repo clone' handles creating the sub-folder (repo name) automatically
        $Arguments = @("repo", "clone", $Repo.Repo)

        # The Execute-Command function will change the directory to $StartDirectory before running 'gh'
        $Result = Execute-Command -Command "gh" -Arguments $Arguments -WorkingDirectory $StartDirectory -RepoIdentifier $Repo.Repo
        
        if (-not $Result.Success) {
            # Store the Result object which contains the failed arguments array
            $FailedClones += $Result
        }
    }

    # 7. Retry Failed Operations
    Retry-FailedOperations -FailedOperations $FailedClones
}

function Bulk-PullRepositories {
    Write-Host "`n--- Bulk Pull Existing Repositories ---" -ForegroundColor Yellow
    
    # Use the new interactive directory function
    $StartDirectory = Get-InteractiveDirectory -PromptMessage "Select the starting folder to search for existing local repositories to pull."

    if ($null -eq $StartDirectory) {
        Write-Host "Operation cancelled." -ForegroundColor Yellow
        return
    }

    # This is the core logic to find repos to PULL (all local repos found)
    $LocalRepos = Get-LocalRepositories -StartDirectory $StartDirectory
    
    if (-not $LocalRepos) { return }

    Write-Host "Starting pull operation on $($LocalRepos.Count) repositories..." -ForegroundColor Yellow

    $FailedPulls = @()

    foreach ($Repo in $LocalRepos) {
        Write-Host "`n-> Pulling ${Repo.Name}..." -ForegroundColor Magenta
        
        # NEW: Arguments are passed as an array of strings
        $Arguments = @("pull", "--ff-only")
        
        # NOTE: We use 'git' directly as we are already inside the repo folder
        $Result = Execute-Command -Command "git" -Arguments $Arguments -WorkingDirectory $Repo.Path -RepoIdentifier $Repo.Name
        
        if (-not $Result.Success) {
            # Store the Result object which contains the failed arguments array
            $FailedPulls += $Result
        }
    }

    # 6. Retry Failed Operations
    Retry-FailedOperations -FailedOperations $FailedPulls
}

# ==============================================================================
# 6. MAIN MENU AND SCRIPT EXECUTION
# ==============================================================================

function Show-MainMenu {
    param(
        [string]$Title = "GitHub Sync and Workflow Tool"
    )

    do {
        Clear-Host
        
        Write-Host "================ $Title ================" -ForegroundColor White
        Write-Host "1: Press '1' to CLONE NEW (Discover and Clone Missing Remote Repos)" -ForegroundColor Green
        Write-Host "2: Press '2' to PULL ALL (Update all existing local repositories)" -ForegroundColor Green
        Write-Host "Q: Press 'Q' to quit" -ForegroundColor Red
        Write-Host "========================================" -ForegroundColor White

        $Selection = Read-Host "Please make a selection"
        $Selection = $Selection.ToUpper()

        switch ($Selection) {
            '1' { Clone-NewRepositories }
            '2' { Bulk-PullRepositories }
            'Q' { Write-Host "Exiting script. Goodbye!" -ForegroundColor Yellow; break }
            default { Write-Host "Invalid selection. Please try again." -ForegroundColor Red; Start-Sleep -Seconds 1 }
        }
        
        if ($Selection -ne 'Q') {
            Write-Host "`nPress any key to return to the main menu..." -ForegroundColor DarkGray
            $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        }

    } while ($Selection -ne 'Q')
}

# --- Main Script Execution ---

if (Check-Prerequisites) {
    Show-MainMenu
} else {
    Write-Host "`nPrerequisites check failed. Please install the required tools and try again." -ForegroundColor Red
}
