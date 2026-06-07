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
#
# -----------------------------------------------------------------------------------------
# JOURNAL DES CORRECTIONS (v1 → v2 → fusion → v3)
# FIX LOG (v1 → v2 → fusion → v3)
# -----------------------------------------------------------------------------------------
# [CORRECTION 1 — BUG CRITIQUE v1] Filtre jq '.[]' → '.workflow_runs[]' (v1+v2)
# [CORRECTION 2 — PAGINATION v1]   Boucle manuelle + wc -l (fragile) → --paginate + jq -s
#                                   (v1+v2) — NOTE : remplacé en CORRECTION 9 (voir ci-dessous)
# [CORRECTION 3 — EN-TÊTE API v1]  Ajout X-GitHub-Api-Version: 2022-11-28 (v1+v2)
# [CORRECTION 4 — SUPPRESSION v1]  'gh run delete --yes' → 'gh api -X DELETE' (v1+v2)
# [CORRECTION 5 — DECLARE -A v1]   Déclaration avant la boucle d'états (v1+v2)
# [CORRECTION 6 — MAPFILE v1]      Ignorer l'élément vide final de mapfile (v1+v2)
# [OPTIMISATION  — GROUPEMENT v2]  declare -A bash O(N jq) → group_by jq O(1) (fusion)
# [CORRECTION 7 — SUBSHELL v2]     pipe | while → < <(...) process substitution (fusion)
#   Cause : 'echo ... | while read' exécute le while dans un subshell ; toute
#   modification de DELETED_COUNT était perdue à la sortie de la boucle (valeur = 0).
#   Référence : ShellCheck SC2031, BashFAQ/024, bash Cookbook 19.8.
#   Cause: 'echo ... | while read' runs the while in a subshell; any DELETED_COUNT
#   modification was lost on loop exit (value = 0).
#   Reference: ShellCheck SC2031, BashFAQ/024, bash Cookbook 19.8.
# [CORRECTION 8 — ARITHMETIC set -e] '((DELETED_COUNT++))' (post-increment) → '+= 1' (fusion)
#   Cause : post-increment renvoie l'ancienne valeur (0 au premier appel) → exit code 1
#   → set -e tue le script dès la première suppression ou simulation.
#   Fix : '((DELETED_COUNT += 1))' — expression vaut la nouvelle valeur (≥1), exit code 0.
#   Référence : alexwlchan.net/notes/2024/errexit-and-arithmetic-expressions, bash pitfalls.
#   Cause: post-increment returns old value (0 on first call) → exit code 1
#   → set -e kills the script on the very first deletion or dry-run count.
#   Fix: '((DELETED_COUNT += 1))' — expression yields new value (≥1), exit code 0.
#   Reference: alexwlchan.net/notes/2024/errexit-and-arithmetic-expressions, bash pitfalls.
# [CORRECTION 9 — PAGINATION v3]   --paginate | jq -s → pagination manuelle + fichier tmp
#   Cause : 'gh api --paginate ... | jq -s' peut échouer silencieusement sur Git Bash /
#   MSYS2 Windows à cause de la gestion des pipes et des process groups : gh garde le flux
#   ouvert entre les pages et jq -s attend une fin de flux qui peut ne jamais signaler EOF
#   dans certains contextes, résultant en 0 run récupéré sans aucun message d'erreur.
#   Fix : boucle page-à-page sans --paginate, accumulation dans un fichier temporaire
#   (évite O(N) forks jq), comptage via 'jq length' (fiable, ≠ wc -l supprimé en
#   CORRECTION 2), slurp unique en fin de fonction. Compatible Windows / Linux / macOS.
#   Cause: 'gh api --paginate ... | jq -s' can fail silently on Git Bash / MSYS2 Windows
#   due to pipe and process group handling: gh keeps the stream open between pages and
#   jq -s awaits an EOF that may never be signalled in some contexts, resulting in 0 runs
#   retrieved with no error message.
#   Fix: page-by-page loop without --paginate, accumulation in a temp file (avoids O(N)
#   jq forks), counting via 'jq length' (reliable, ≠ wc -l removed in FIX 2), single
#   slurp at end of function. Compatible with Windows / Linux / macOS.
# =========================================================================================================

set -euo pipefail

# ================= CONFIGURATION =================
OWNER="Phoen0x"
REPO="QuelleHeureEst-Il.com"

# Nombre de runs les plus anciens et les plus récents à conserver (par état et par workflow)
# Number of oldest and newest runs to keep (per status and per workflow)
KEEP_OLDEST=3
KEEP_NEWEST=3

# Mode dry-run : true = affiche uniquement, false = supprime réellement
# Dry-run mode: true = display only, false = actually delete
DRY_RUN=true                  # Passe à true pour tester sans supprimer, Passe à false pour supprimer réellement. /  ENG//  Set to false to actually delete.

# États à traiter (laisser vide pour tous les états)
# Statuses to process (leave empty for all statuses)
# États possibles : success, failure, cancelled, skipped, action_required, neutral, timed_out
# Possible statuses: success, failure, cancelled, skipped, action_required, neutral, timed_out
FILTER_STATUS=()               # Exemple / Example : ("success" "failure"), Vide / Empty = tous les états / all states.

# Limite de runs à récupérer par appel API (max GitHub = 100)
# Limit of runs fetched per API call (GitHub max = 100)
PER_PAGE=100

# Mise en place de la variable qui sera amenée à être modifiée : Compteur de runs supprimés (réellement ou en dry-run) — doit rester dans le shell courant
# Counter of deleted runs (real or dry-run) — must stay in the current shell (not a subshell)
DELETED_COUNT=0

# Délai entre suppressions réelles pour éviter le rate limiting API (en secondes)
# Delay between real deletions to avoid API rate limiting (in seconds)
RATE_LIMIT_DELAY=0.5

# ======================================
# Vérifications préalables
# Pre-flight checks
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
#   FR//  Fonctions
#  ENG//  Functions
# =================================================

# Fonction pour récupérer TOUS les runs du dépôt (tous workflows, y compris supprimés)
# Function to retrieve ALL repository runs (all workflows, including deleted ones)
get_all_runs() {
    # Pagination manuelle sans --paginate (compatibilité Git Bash / Windows)
    # Manual pagination without --paginate (Git Bash / Windows compatibility)
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
    #   Note : --paginate --slurp existe mais est incompatible avec --jq (gh CLI limitation).
    # [FIX 2 — PAGINATION] Replaced the manual loop + wc -l (fragile, wc -l can be
    #   inaccurate) with gh's native --paginate + jq -s to merge pages.
    #   --paginate with --jq emits one JSON object per line (JSON Lines); jq -s '.'
    #   cleanly collects them into a single array.
    #   Note: --paginate --slurp exists but is incompatible with --jq (gh CLI limitation).
    #
    # [CORRECTION 3 — EN-TÊTE API] Ajout de X-GitHub-Api-Version: 2022-11-28, bonne
    #   pratique officielle GitHub depuis nov. 2022 pour stabilité et compatibilité future.
    # [FIX 3 — API HEADER] Added X-GitHub-Api-Version: 2022-11-28, official GitHub best
    #   practice since Nov. 2022 for stability and future compatibility.
    #
    # [CORRECTION 9 — PAGINATION v3] Remplacement de '--paginate | jq -s' (échouait
    #   silencieusement sur Git Bash Windows) par une boucle page-à-page qui :
    #   - N'utilise PAS --paginate (contourne le problème de pipe/EOF Git Bash).
    #   - Accumule les JSON Lines dans un fichier temporaire (pas de fork jq par run).
    #   - Compte les runs via 'jq .workflow_runs | length' (fiable, ≠ wc -l qui était
    #     fragile et avait déjà été supprimé en CORRECTION 2).
    #   - Effectue un unique 'jq -s .' final sur le fichier tmp : O(1) en forks jq.
    #   - Affiche les erreurs API sur stderr au lieu de les masquer (2>/dev/null supprimé).
    #   - Nettoie systématiquement le fichier temporaire via un trap RETURN.
    # [FIX 9 — PAGINATION v3] Replaced '--paginate | jq -s' (silent failure on Git Bash
    #   Windows) with a page-by-page loop that:
    #   - Does NOT use --paginate (works around Git Bash pipe/EOF issue).
    #   - Accumulates JSON Lines in a temp file (no per-run jq fork).
    #   - Counts runs via 'jq .workflow_runs | length' (reliable, ≠ wc -l which was
    #     fragile and had already been removed in FIX 2).
    #   - Performs a single final 'jq -s .' on the tmp file: O(1) jq forks.
    #   - Prints API errors to stderr instead of silencing them (2>/dev/null removed).
    #   - Always cleans up the temp file via a RETURN trap.

    local tmpfile
    # Créer un fichier temporaire pour accumuler les JSON Lines page par page
    # Create a temp file to accumulate JSON Lines page by page
    tmpfile=$(mktemp) || {
        echo "❌ Impossible de créer un fichier temporaire (mktemp)." >&2
        return 1
    }

    # Nettoyage garanti du fichier temporaire à la sortie de la fonction (succès ou erreur)
    # Guaranteed temp file cleanup on function exit (success or error)
    # shellcheck disable=SC2064
    trap "rm -f '$tmpfile'" RETURN

    local page=1
    local page_count

    while true; do
        local raw_page
        # Récupérer la page brute (objet JSON complet, sans filtrage) pour pouvoir
        # compter via jq length — fiable contrairement à wc -l.
        # Fetch the raw page (full JSON object, no filtering) so we can count
        # via jq length — reliable unlike wc -l.
        if ! raw_page=$(gh api \
                -H "Accept: application/vnd.github+json" \
                -H "X-GitHub-Api-Version: 2022-11-28" \
                "repos/$OWNER/$REPO/actions/runs?page=$page&per_page=$PER_PAGE" 2>&1); then
            # Afficher l'erreur sur stderr et sortir de la boucle proprement
            # Print the error on stderr and exit the loop cleanly
            echo "⚠️ Erreur API page $page : $raw_page" >&2
            break
        fi

        # Compter le nombre de runs dans cette page via jq (fiable)
        # Count the number of runs in this page via jq (reliable)
        page_count=$(echo "$raw_page" | jq '.workflow_runs | length')

        # Fin de pagination : page vide → on arrête
        # End of pagination: empty page → stop
        if [[ "$page_count" -eq 0 ]]; then
            break
        fi

        # Extraire uniquement les champs utiles et ajouter une ligne JSON par run dans tmpfile
        # Extract only the needed fields and append one JSON line per run to tmpfile
        echo "$raw_page" | jq -c \
            '.workflow_runs[] | {id, created_at, status, conclusion, workflow_id}' \
            >> "$tmpfile"

        # Fin de pagination : page incomplète → c'est la dernière page
        # End of pagination: partial page → this is the last page
        if [[ "$page_count" -lt "$PER_PAGE" ]]; then
            break
        fi

        # [CORRECTION 8 — cohérence] Post-incrément '++' banni du script (cf. CORRECTION 8).
        # [FIX 8 — consistency] Post-increment '++' banned from script (see FIX 8).
        ((page += 1))
    done

    # Slurp unique : transformer les JSON Lines du fichier tmp en un tableau JSON valide.
    # Coût : UN seul processus jq, quelle que soit la quantité de runs — O(1).
    # Single slurp: transform the JSON Lines in the tmp file into a valid JSON array.
    # Cost: ONE single jq process, regardless of run count — O(1).
    jq -s '.' "$tmpfile"
    # Note : le trap RETURN supprime tmpfile automatiquement après ce return implicite.
    # Note: the RETURN trap deletes tmpfile automatically after this implicit return.
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
        # [CORRECTION 8 — ARITHMETIC set -e] '((DELETED_COUNT++))' retourne exit code 1
        #   quand DELETED_COUNT vaut 0 (post-incrément renvoie l'ancienne valeur : 0 = faux).
        #   Avec set -e, ça tue le script dès la première itération. Fix : '+= 1' dont
        #   l'expression vaut la NOUVELLE valeur (≥1 dès le début), exit code toujours 0.
        #   Refs : bash pitfalls, alexwlchan.net/notes/2024/errexit-and-arithmetic-expressions
        # [FIX 8 — ARITHMETIC set -e] '((DELETED_COUNT++))' returns exit code 1 when
        #   DELETED_COUNT is 0 (post-increment yields old value: 0 = false).
        #   With set -e, this kills the script on the very first iteration. Fix: '+= 1'
        #   whose expression value is the NEW value (≥1 immediately), exit code always 0.
        #   Refs: bash pitfalls, alexwlchan.net/notes/2024/errexit-and-arithmetic-expressions
        ((DELETED_COUNT += 1))
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
            ((DELETED_COUNT += 1))
        else
            echo "      ⚠️ Échec suppression $run_id"
        fi
        # Rate limiting : attendre un délai configurable entre chaque suppression réelle
        # Rate limiting: wait a configurable delay between each real deletion
        sleep "$RATE_LIMIT_DELAY"
    fi
}

# =================================================
# Traitement principal
# Main processing
# =================================================

# Récupérer TOUS les runs du dépôt (sans passer par la liste des workflows)
# Retrieve ALL repository runs (without going through the workflow list)
echo "🔍 Récupération de TOUTES les runs du dépôt (y compris workflows supprimés)..."
ALL_RUNS=$(get_all_runs)
TOTAL_RUNS=$(echo "$ALL_RUNS" | jq length)

if [[ "$TOTAL_RUNS" -eq 0 ]]; then
    echo "  → Aucun run trouvé."
    exit 0
fi
echo "  → $TOTAL_RUNS runs récupérés."

# [OPTIMISATION — GROUPEMENT v2] Regroupement par workflow_id en une seule passe jq
#   (group_by) au lieu de la boucle bash du fichier 1 (un fork jq par run, soit O(N)).
#   Pour 500 runs, la v1 lançait 500 processus jq ; ici, un seul.
# [OPTIMIZATION — GROUPING v2] Group by workflow_id in a single jq pass (group_by)
#   instead of file 1's bash loop (one jq fork per run = O(N)).
#   For 500 runs, v1 spawned 500 jq processes; here, just one.
WORKFLOW_GROUPS=$(echo "$ALL_RUNS" | jq -c '
    group_by(.workflow_id) |
    map({
        workflow_id: .[0].workflow_id,
        runs: .
    })
')

# [CORRECTION 7 — SUBSHELL v2] La v2 utilisait un pipe ('echo ... | while read'),
#   ce qui exécute le while dans un subshell : DELETED_COUNT était toujours 0 en sortie
#   de boucle, car les modifications dans un subshell ne remontent jamais au shell parent.
#   Correction : process substitution '< <(...)' — le while tourne dans le shell courant.
#   Références : ShellCheck SC2031, BashFAQ/024, bash Cookbook chap. 19.8.
# [FIX 7 — SUBSHELL v2] v2 used a pipe ('echo ... | while read'), which runs the
#   while loop in a subshell: DELETED_COUNT was always 0 after the loop, because
#   variable changes in a subshell never propagate to the parent shell.
#   Fix: process substitution '< <(...)' — the while runs in the current shell.
#   References: ShellCheck SC2031, BashFAQ/024, bash Cookbook chap. 19.8.
while read -r group; do
    workflow_id=$(echo "$group" | jq -r '.workflow_id')
    RUNS_JSON=$(echo "$group" | jq -c '.runs')
    TOTAL_RUNS_WF=$(echo "$RUNS_JSON" | jq length)
    WORKFLOW_NAME=$(get_workflow_name "$workflow_id")

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

    # [CORRECTION 5 — DECLARE -A] Le tableau associatif est déclaré ici, avant la boucle
    #   d'états. Avec le fix subshell (< <(...)), le while tourne dans le shell parent :
    #   'unset KEEP_IDS' en fin de workflow le supprime proprement, et la prochaine
    #   itération le redéclare depuis zéro — comportement stable sur Bash 4+.
    # [FIX 5 — DECLARE -A] The associative array is declared here, before the status loop.
    #   With the subshell fix (< <(...)), the while runs in the parent shell:
    #   'unset KEEP_IDS' at end of workflow cleanly removes it, and the next iteration
    #   re-declares it from scratch — stable behavior on Bash 4+.
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

done < <(echo "$WORKFLOW_GROUPS" | jq -c '.[]')
# ↑ [CORRECTION 7] Process substitution : le while tourne dans le shell courant,
#   DELETED_COUNT est donc correctement incrémenté et visible après la boucle.
# ↑ [FIX 7] Process substitution: the while runs in the current shell,
#   so DELETED_COUNT is correctly incremented and visible after the loop.

# Afficher le résumé des suppressions
# Display deletion summary
echo ""
echo "📊 Résumé :"
echo "   • Runs examinées : $TOTAL_RUNS"
echo "   • Runs supprimés : $DELETED_COUNT"
if [[ "$DRY_RUN" == true ]]; then
    echo "   (Mode DRY RUN : aucune suppression réelle)"
else
    echo "   (Mode réel : $DELETED_COUNT runs supprimés)"
fi

echo ""
echo "✅ Opération terminée (dry-run=$DRY_RUN)."
