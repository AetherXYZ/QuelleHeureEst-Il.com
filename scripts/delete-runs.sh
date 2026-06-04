#!/bin/bash
# =============================================================================
# delete-runs-advanced.sh
# =============================================================================
# But : Garder uniquement les N runs les plus anciens et les N runs les plus récents
#       par état (success, failure, etc.) pour chaque workflow GitHub Actions.
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
#   ./delete-runs-advanced.sh
#
# Configuration (modifier les valeurs ci-dessous) :
#   OWNER         : organisation ou utilisateur propriétaire du dépôt
#   REPO          : nom du dépôt
#   KEEP_OLDEST   : nombre de runs les plus anciens à conserver (par état)
#   KEEP_NEWEST   : nombre de runs les plus récents à conserver (par état)
#   DRY_RUN       : true  = simulation (aucune suppression)
#                   false = suppression réelle
#   FILTER_STATUS : laisser vide pour tous les états, ou mettre ex: ("success" "failure")
# =============================================================================

set -euo pipefail

# ================= CONFIGURATION =================
OWNER="Phoen0x"
REPO="QuelleHeureEst-Il.com"

# Nombre de runs les plus anciens et les plus récents à conserver (par état)
KEEP_OLDEST=3
KEEP_NEWEST=3

# Mode dry-run : true = affiche uniquement, false = supprime réellement
DRY_RUN=false                  # Passe à true pour tester sans supprimer

# États à traiter (laisser vide pour tous les états)
# États possibles : success, failure, cancelled, skipped, action_required, neutral, timed_out
# Exemple : FILTER_STATUS=("success" "failure")
FILTER_STATUS=()               # Exemple : ("success" "failure"), Vide = tous les états.

# Limite de runs à récupérer par appel API (max GitHub = 100)
PER_PAGE=100

# =================================================
# Vérifications préalables
# =================================================

# Vérifier que gh est disponible
if ! command -v gh &> /dev/null; then
    echo "❌ gh (GitHub CLI) non installé. Exécute les commandes PowerShell ci-dessus."
    exit 1
fi

# Vérifier que jq est disponible
if ! command -v jq &> /dev/null; then
    echo "❌ jq (JSON processor) non installé. Installe-le via les commandes fournies."
    exit 1
fi

# Vérifier l'authentification
if ! gh auth status &> /dev/null; then
    echo "❌ gh non authentifié. Lance 'gh auth login' avec les bons scopes."
    exit 1
fi

# =================================================
# Fonctions
# =================================================

# Fonction pour récupérer TOUS les runs d'un workflow avec pagination (via gh api)
# Utilise gh api directement car gh run list ne gère pas nativement la pagination complète
# Arguments : workflow_name (string)
# Retourne : JSON list (tableau d'objets avec id, created_at, status, conclusion)
get_all_runs() {
    local workflow="$1"
    local page=1
    local all_runs="[]"
    
    while true; do
        # Construire la requête API (encoder les espaces dans le nom du workflow)
        local query="repos/$OWNER/$REPO/actions/workflows/${workflow// /%20}/runs?page=$page&per_page=$PER_PAGE"
        local response
        response=$(gh api "$query" --jq '.workflow_runs[] | {id: .id, created_at: .created_at, status: .status, conclusion: .conclusion}' 2>/dev/null) || break
        
        if [[ -z "$response" ]]; then
            break
        fi
        
        # Convertir chaque ligne en objet JSON et les ajouter au tableau
        while IFS= read -r line; do
            if [[ -n "$line" ]]; then
                all_runs=$(jq --argjson new "$line" '. + [$new]' <<<"$all_runs")
            fi
        done <<< "$response"
        
        # Compter le nombre de lignes reçues (chaque run = une ligne)
        local count
        count=$(echo "$response" | wc -l)
        
        # Si on a reçu moins que PER_PAGE, c'est la dernière page
        if [[ $count -lt $PER_PAGE ]]; then
            break
        fi

        ((page++))
    done
    
    echo "$all_runs"
}

# Fonction pour afficher (et éventuellement supprimer ou simuler) un run
process_run() {
    local run_id="$1"
    local reason="$2"
    
    if [[ "$DRY_RUN" == true ]]; then
        echo "      🔍 [DRY RUN] Serait supprimé : run $run_id ($reason)"
    else
        echo "      🗑️ Suppression du run $run_id ($reason)"
        gh run delete --repo "$OWNER/$REPO" --yes "$run_id" || echo "      ⚠️ Échec suppression $run_id"
    fi
}

# =================================================
# Traitement principal
# =================================================

# Récupérer tous les workflows
echo "🔍 Récupération de la liste des workflows..."
# Lister tous les workflows (en utilisant --json pour éviter les problèmes de formatage)
WORKFLOW_NAMES=$(gh workflow list --repo "$OWNER/$REPO" --json name --jq '.[].name')

# Boucle sur chaque workflow (gère les noms avec espaces)
echo "$WORKFLOW_NAMES" | while IFS= read -r WORKFLOW; do
    [[ -z "$WORKFLOW" ]] && continue
    echo ""
    echo "📦 Workflow : $WORKFLOW"
    
    # Récupérer tous les runs (avec pagination)
    RUNS_JSON=$(get_all_runs "$WORKFLOW")
    TOTAL_RUNS=$(echo "$RUNS_JSON" | jq length)
    
    if [[ "$TOTAL_RUNS" -eq 0 ]]; then
        echo "  → Aucun run trouvé."
        continue
    fi
    
    # Déterminer les états à traiter
    if [[ ${#FILTER_STATUS[@]} -eq 0 ]]; then
        # Extraire tous les états présents dans les runs (conclusion prioritaire, sinon status)
        STATES=$(echo "$RUNS_JSON" | jq -r '.[].conclusion // .[].status' | sort -u)
        mapfile -t STATES_ARRAY <<< "$STATES"
    else
        STATES_ARRAY=("${FILTER_STATUS[@]}")
    fi
    
    # Pour chaque état, garder les KEEP_OLDEST plus anciens et KEEP_NEWEST plus récents
    for STATE in "${STATES_ARRAY[@]}"; do
        # Filtrer les runs correspondant à cet état (conclusion ou status)
        RUNS_STATE=$(echo "$RUNS_JSON" | jq --arg state "$STATE" '[.[] | select((.conclusion // .status) == $state)]')
        COUNT=$(echo "$RUNS_STATE" | jq length)
        
        if [[ "$COUNT" -eq 0 ]]; then
            continue
        fi
        
        # Trier par date croissante (plus ancien en premier)
        SORTED=$(echo "$RUNS_STATE" | jq 'sort_by(.created_at)')
        
        # IDs des runs à conserver : les KEEP_OLDEST premiers et KEEP_NEWEST derniers
        # Utilisation d'un tableau associatif pour marquer les runs à garder
        declare -A KEEP_IDS
        
        # Ajouter les plus anciens
        for ((i=0; i<KEEP_OLDEST && i<COUNT; i++)); do
            id=$(echo "$SORTED" | jq -r ".[$i].id")
            KEEP_IDS["$id"]=1
        done
        
        # Ajouter les plus récents (en partant de la fin)
        for ((i=0; i<KEEP_NEWEST && i<COUNT; i++)); do
            idx=$((COUNT - 1 - i))
            id=$(echo "$SORTED" | jq -r ".[$idx].id")
            KEEP_IDS["$id"]=1
        done
        
        # Parcourir tous les runs de cet état et supprimer ceux qui ne sont pas dans KEEP_IDS
        for run_id in $(echo "$RUNS_STATE" | jq -r '.[].id'); do
            if [[ -z "${KEEP_IDS[$run_id]:-}" ]]; then
                process_run "$run_id" "état=$STATE, ni parmi les $KEEP_OLDEST plus vieux ni les $KEEP_NEWEST plus récents"
            fi
        done
        
        unset KEEP_IDS
    done
done

echo ""
echo "✅ Opération terminée (dry-run=$DRY_RUN)."
