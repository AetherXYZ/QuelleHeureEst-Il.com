#!/bin/bash
# =========================================================================================================
# Nettoyage_du_Dépôt.sh
# =========================================================================================================
# But : Garder uniquement les N runs les plus anciens et les N runs les plus récents
#       par état (success, failure, etc.) pour CHAQUE workflow GitHub Actions.
#
# PRÉREQUIS ET INSTALLATION (PowerShell en administrateur) :
#
# --- 1. Installer / mettre à jour GitHub CLI (gh) ---
# winget install --id GitHub.cli --source winget --accept-package-agreements --accept-source-agreements
# ou si winget n'est pas disponible :
#   curl -L -o gh.msi https://github.com/cli/cli/releases/latest/download/gh_win32.msi
#   msiexec /i gh.msi /quiet
#
# --- 2. Installer / mettre à jour jq (JSON parser) ---
# winget install --id=jqlang.jq -e
# ou téléchargement direct :
#   curl -L -o jq.exe https://github.com/jqlang/jq/releases/latest/download/jq-win64.exe
#   move jq.exe "C:\Program Files\Git\usr\bin\jq.exe"   # pour le rendre accessible dans Git Bash
#
# --- 3. Vérifier l'authentification gh ---
# gh auth status
# Si non connecté : gh auth login
#    Scopes nécessaires : repo, workflow, delete_workflow_runs
#
# --- 4. (Optionnel) Tester en mode dry-run ---
#    Modifier DRY_RUN=true dans la configuration ci-dessous
#
# Utilisation :
#   ./Nettoyage_du_Dépôt.sh
#
# Configuration (modifier les valeurs ci-dessous) :
#   OWNER         : organisation ou utilisateur propriétaire du dépôt
#   REPO          : nom du dépôt
#   KEEP_OLDEST   : nombre de runs les plus anciens à conserver (par état et par workflow)
#   KEEP_NEWEST   : nombre de runs les plus récents à conserver (par état et par workflow)
#   DRY_RUN       : true  = simulation (aucune suppression)
#                   false = suppression réelle
#   FILTER_STATUS : laisser vide pour tous les états, ou mettre ex: ("success" "failure")
# =========================================================================================================

set -euo pipefail

# ================= CONFIGURATION =================
OWNER="Phoen0x"
REPO="QuelleHeureEst-Il.com"

# Nombre de runs les plus anciens et les plus récents à conserver (par état et par workflow)
KEEP_OLDEST=3
KEEP_NEWEST=3

# Mode dry-run : true = affiche uniquement, false = supprime réellement
DRY_RUN=true                  # Passe à true pour tester sans supprimer

# États à traiter (laisser vide pour tous les états)
# États possibles : success, failure, cancelled, skipped, action_required, neutral, timed_out
FILTER_STATUS=()               # Exemple : ("success" "failure"), Vide = tous les états.

# Limite de runs à récupérer par appel API (max GitHub = 100)
PER_PAGE=100

# Mise en place de la variable qui sera amenée à être modifiée : Compteur de runs supprimés (réellement ou en dry-run)
DELETED_COUNT=0

# ======================================
# Vérifications préalables
# ======================================

# Vérifier que gh est disponible
# Check that gh is available
if ! command -v gh &> /dev/null; then
    echo "❌ gh (GitHub CLI) non installé. Exécute les commandes PowerShell ci-dessus."
    exit 1
fi

# Vérifier que jq est disponible
# Check that jq is available
if ! command -v jq &> /dev/null; then
    echo "❌ jq (JSON processor) non installé. Installe-le via les commandes fournies."
    exit 1
fi

# Vérifier l'authentification
# Check authentication
if ! gh auth status &> /dev/null; then
    echo "❌ gh non authentifié. Lance 'gh auth login' avec les bons scopes."
    exit 1
fi

# =================================================
# Fonctions
# =================================================

# Fonction pour récupérer TOUS les runs du dépôt (tous workflows, y compris supprimés)
# Function to retrieve ALL repository runs (all workflows, including deleted ones)
get_all_runs() {
    # [CORRECTION 1 — BUG CRITIQUE] Le filtre jq était '.[]' ce qui itère sur TOUS les
    #   champs de l'objet de réponse (total_count ET workflow_runs), causant 0 run récupéré.
    #   L'endpoint /actions/runs retourne {"total_count": N, "workflow_runs": [...]}, pas
    #   un tableau direct. Filtre corrigé : .workflow_runs[].
    # [FIX 1 — CRITICAL BUG] The jq filter was '.[]' which iterates over ALL fields of the
    #   response object (total_count AND workflow_runs), causing 0 runs to be retrieved.
    #   The /actions/runs endpoint returns {"total_count": N, "workflow_runs": [...]}, not
    #   a bare array. Corrected filter: .workflow_runs[].
    #
    # [CORRECTION 2 — PAGINATION] Remplacement de la boucle manuelle + wc -l (fragile,
    #   wc -l peut être inexact) par --paginate natif de gh + jq -s pour merger les pages.
    #   --paginate avec --jq émet un objet JSON par ligne (JSON Lines) ; jq -s '.' les
    #   collecte proprement en un seul tableau.
    # [FIX 2 — PAGINATION] Replaced the manual loop + wc -l (fragile, wc -l can be
    #   inaccurate) with gh's native --paginate + jq -s to merge pages.
    #   --paginate with --jq emits one JSON object per line (JSON Lines); jq -s '.'
    #   cleanly collects them into a single array.
    #
    # [CORRECTION 3 — EN-TÊTE API] Ajout de X-GitHub-Api-Version: 2022-11-28, bonne
    #   pratique officielle GitHub depuis nov. 2022 pour stabilité et compatibilité future.
    # [FIX 3 — API HEADER] Added X-GitHub-Api-Version: 2022-11-28, official GitHub best
    #   practice since Nov. 2022 for stability and future compatibility.
    gh api --paginate \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "repos/$OWNER/$REPO/actions/runs?per_page=$PER_PAGE" \
        --jq '.workflow_runs[] | {id: .id, created_at: .created_at, status: .status, conclusion: .conclusion, workflow_id: .workflow_id}' \
    | jq -s '.'
    # Note : jq -s '.' slurpe le flux JSON Lines en un tableau JSON valide.
    # Note: jq -s '.' slurps the JSON Lines stream into a valid JSON array.
}

# Fonction pour obtenir le nom d'un workflow à partir de son ID (pour l'affichage)
# Function to get a workflow's name from its ID (for display purposes)
get_workflow_name() {
    local workflow_id="$1"
    local name
    # [CORRECTION 3 — EN-TÊTE API] Ajout de X-GitHub-Api-Version sur tous les appels gh api.
    # [FIX 3 — API HEADER] Added X-GitHub-Api-Version to all gh api calls.
    name=$(gh api \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "repos/$OWNER/$REPO/actions/workflows/$workflow_id" \
        --jq '.name' 2>/dev/null) || true
    if [[ -z "$name" ]]; then
        # Le workflow a probablement été supprimé mais ses runs subsistent
        # The workflow was likely deleted but its runs still exist
        name="workflow_$workflow_id (peut-être supprimé / possibly deleted)"
    fi
    echo "$name"
}

# Fonction pour afficher (et éventuellement supprimer ou simuler) un run
# Function to display (and optionally delete or simulate) a run
process_run() {
    local run_id="$1"
    local reason="$2"
    
    if [[ "$DRY_RUN" == true ]]; then
        echo "      🔍 [DRY RUN] Serait supprimé : run $run_id ($reason)"
        ((DELETED_COUNT++))
    else
        echo "      🗑️ Suppression du run $run_id ($reason)"
        # [CORRECTION 4 — SUPPRESSION] 'gh run delete --yes' n'existe pas (--yes n'est pas
        #   un flag valide de gh run delete). Remplacement par 'gh api -X DELETE' qui est
        #   fiable, non-interactif, et conforme aux exemples officiels de la communauté GitHub.
        # [FIX 4 — DELETION] 'gh run delete --yes' doesn't work (--yes is not a valid flag
        #   for gh run delete). Replaced with 'gh api -X DELETE' which is reliable,
        #   non-interactive, and consistent with official GitHub community examples.
        if gh api -X DELETE \
            -H "Accept: application/vnd.github+json" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            "repos/$OWNER/$REPO/actions/runs/$run_id" \
            > /dev/null 2>&1; then
            ((DELETED_COUNT++))
        else
            echo "      ⚠️ Échec suppression $run_id"
        fi
        # Rate limiting : attendre 0.5 seconde entre chaque suppression réelle
        sleep 0.5
    fi
}

# =================================================
# Traitement principal
# =================================================

# Récupérer TOUS les runs du dépôt (sans passer par la liste des workflows)
echo "🔍 Récupération de TOUTES les runs du dépôt (y compris workflows supprimés)..."
ALL_RUNS=$(get_all_runs)
TOTAL_RUNS=$(echo "$ALL_RUNS" | jq length)

if [[ "$TOTAL_RUNS" -eq 0 ]]; then
    echo "  → Aucun run trouvé."
    exit 0
fi
echo "  → $TOTAL_RUNS runs récupérés."

# Grouper les runs par workflow_id (création d'un tableau associatif workflow_id -> liste de runs)
# Group runs by workflow_id (build an associative array workflow_id -> list of runs)
declare -A WORKFLOW_RUNS

# Parcourir chaque run et l'ajouter à son workflow
# Iterate each run and add it to its workflow bucket
while IFS= read -r run; do
    workflow_id=$(echo "$run" | jq -r '.workflow_id')
    # Initialiser le tableau pour ce workflow si nécessaire
    # Initialize the bucket for this workflow if needed
    if [[ -z "${WORKFLOW_RUNS[$workflow_id]:-}" ]]; then
        WORKFLOW_RUNS[$workflow_id]="[]"
    fi
    # Ajouter le run à la liste du workflow
    # Append the run to the workflow's list
    WORKFLOW_RUNS[$workflow_id]=$(jq --argjson new "$run" '. + [$new]' <<<"${WORKFLOW_RUNS[$workflow_id]}")
done < <(echo "$ALL_RUNS" | jq -c '.[]')

# Traiter chaque workflow séparément
# Process each workflow independently
for workflow_id in "${!WORKFLOW_RUNS[@]}"; do
    WORKFLOW_NAME=$(get_workflow_name "$workflow_id")
    RUNS_JSON="${WORKFLOW_RUNS[$workflow_id]}"
    TOTAL_RUNS_WF=$(echo "$RUNS_JSON" | jq length)
    
    echo ""
    echo "📦 Workflow : $WORKFLOW_NAME (ID: $workflow_id) — $TOTAL_RUNS_WF runs"
    
    # Déterminer les états à traiter pour ce workflow
    # Determine which statuses to process for this workflow
    if [[ ${#FILTER_STATUS[@]} -eq 0 ]]; then
        # Extraire tous les états présents (conclusion prioritaire, sinon status)
        # Extract all present statuses (conclusion takes priority over status)
        STATES=$(echo "$RUNS_JSON" | jq -r '.[].conclusion // .[].status' | sort -u)
        mapfile -t STATES_ARRAY <<< "$STATES"
    else
        STATES_ARRAY=("${FILTER_STATUS[@]}")
    fi
    
    # [CORRECTION 5 — DECLARE -A] Le tableau associatif était déclaré à l'intérieur de la
    #   boucle d'états, ce qui peut provoquer des redéclarations surprenantes (notamment
    #   sous Bash < 5 ou après un 'unset'). Déclaration déplacée ici, avant la boucle, avec
    #   KEEP_IDS=() pour réinitialiser proprement à chaque itération d'état.
    # [FIX 5 — DECLARE -A] The associative array was declared inside the status loop, which
    #   can cause surprising re-declaration behavior (especially on Bash < 5 or after 'unset').
    #   Declaration moved here, before the loop, with KEEP_IDS=() to cleanly reset on each
    #   status iteration.
    declare -A KEEP_IDS
    
    # Pour chaque état, garder les KEEP_OLDEST plus anciens et KEEP_NEWEST plus récents
    # For each status, keep the KEEP_OLDEST oldest and KEEP_NEWEST most recent runs
    for STATE in "${STATES_ARRAY[@]}"; do
        # [CORRECTION 6 — MAPFILE] mapfile peut insérer un élément vide sur la dernière
        #   ligne si STATES se termine par un saut de ligne. On l'ignore explicitement.
        # [FIX 6 — MAPFILE] mapfile may insert an empty element on the last line if STATES
        #   ends with a newline. We explicitly skip it.
        [[ -z "$STATE" ]] && continue
        
        # Filtrer les runs correspondant à cet état (conclusion ou status)
        # Filter runs matching this status (conclusion or status field)
        RUNS_STATE=$(echo "$RUNS_JSON" | jq --arg state "$STATE" '[.[] | select((.conclusion // .status) == $state)]')
        COUNT=$(echo "$RUNS_STATE" | jq length)
        
        if [[ "$COUNT" -eq 0 ]]; then
            continue
        fi
        
        echo "  🏷️  État : $STATE — $COUNT runs"
        
        # Trier par date croissante (plus ancien en premier)
        # Sort by ascending date (oldest first)
        SORTED=$(echo "$RUNS_STATE" | jq 'sort_by(.created_at)')
        
        # Réinitialiser le tableau associatif pour cet état (proprement, sans redéclaration)
        # Reset the associative array for this status (cleanly, without re-declaring)
        KEEP_IDS=()
        
        # IDs des runs à conserver : les KEEP_OLDEST premiers et KEEP_NEWEST derniers
        # Run IDs to keep: the KEEP_OLDEST first and KEEP_NEWEST last
        
        # Ajouter les plus anciens / Add the oldest
        for ((i=0; i<KEEP_OLDEST && i<COUNT; i++)); do
            id=$(echo "$SORTED" | jq -r ".[$i].id")
            KEEP_IDS["$id"]=1
        done
        
        # Ajouter les plus récents (en partant de la fin) / Add the most recent (from the end)
        for ((i=0; i<KEEP_NEWEST && i<COUNT; i++)); do
            idx=$((COUNT - 1 - i))
            id=$(echo "$SORTED" | jq -r ".[$idx].id")
            KEEP_IDS["$id"]=1
        done
        
        # Parcourir tous les runs de cet état et supprimer ceux qui ne sont pas dans KEEP_IDS
        # Iterate all runs for this status and delete those not in KEEP_IDS
        for run_id in $(echo "$RUNS_STATE" | jq -r '.[].id'); do
            if [[ -z "${KEEP_IDS[$run_id]:-}" ]]; then
                process_run "$run_id" "état=$STATE, workflow $WORKFLOW_NAME, ni parmi les $KEEP_OLDEST plus vieux ni les $KEEP_NEWEST plus récents"
            fi
        done
    done
    
    # Nettoyer le tableau associatif après chaque workflow
    # Clean up the associative array after each workflow
    unset KEEP_IDS
done

# Afficher le résumé des suppressions
echo ""
echo "📊 Résumé :"
echo "   • Runs examinés : $TOTAL_RUNS"
echo "   • Runs supprimés : $DELETED_COUNT"
if [[ "$DRY_RUN" == true ]]; then
    echo "   (Mode DRY RUN : aucune suppression réelle)"
else
    echo "   (Mode réel : $DELETED_COUNT runs supprimés)"
fi

echo ""
echo "✅ Opération terminée (dry-run=$DRY_RUN)."
