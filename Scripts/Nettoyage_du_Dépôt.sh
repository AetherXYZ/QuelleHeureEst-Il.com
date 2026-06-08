#!/bin/bash
# =========================================================================================================
# Nettoyage_du_Dépôt.sh
# =========================================================================================================
# But : Garder uniquement les N runs les plus anciens et les N runs les plus récents
#       par état (success, failure, etc.) pour CHAQUE workflow GitHub Actions.
#       Optionnellement : ignorer les runs déclenchés manuellement (workflow_dispatch),
#       et/ou supprimer TOUTES les runs des workflows dont le fichier de config a disparu du dépôt.
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
#   OWNER            : organisation ou utilisateur propriétaire du dépôt
#   REPO             : nom du dépôt
#   KEEP_OLDEST      : nombre de runs les plus anciens à conserver (par état et par workflow)
#   KEEP_NEWEST      : nombre de runs les plus récents à conserver (par état et par workflow)
#   DRY_RUN          : true  = simulation (aucune suppression)
#                      false = suppression réelle
#   FILTER_STATUS    : laisser vide pour tous les états, ou mettre ex: ("success" "failure")
#   SKIP_MANUAL      : true  = les runs déclenchés manuellement (workflow_dispatch) sont
#                              complètement ignorées : ni supprimées, ni comptées dans KEEP_OLDEST/NEWEST
#                      false = tous les runs sont traités normalement (défaut)
#   DELETE_ORPHANED  : true  = si un workflow n'a plus de fichier de config actif dans le dépôt
#                              (fichier .yml supprimé ou workflow désactivé), TOUS ses runs sont
#                              supprimées sans tenir compte de KEEP_OLDEST / KEEP_NEWEST
#                      false = les workflows orphelins sont traités comme les autres (défaut)
#
# -----------------------------------------------------------------------------------------
# JOURNAL DES CORRECTIONS ET FONCTIONNALITÉS (v1 → v2 → fusion → v3 → v4)
# FIX AND FEATURE LOG (v1 → v2 → fusion → v3 → v4)
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
# [CORRECTION 10 — CRLF Git Bash]  \r parasite dans les IDs extraits par jq -r sur Windows
#   Cause : sur Git Bash / MSYS2 Windows, 'jq -r' peut émettre des fins de ligne \r\n au
#   lieu de \n. '$()' strip le \n final mais PAS le \r → l'ID devient "12345\r" → la clé
#   dans KEEP_IDS est "12345\r" → l'URL de l'API vaut '.../runs/12345\r' (invalide) →
#   l'appel gh api -X DELETE échoue silencieusement (masqué par > /dev/null 2>&1).
#   Fix racine : '| tr -d '\r'' ajouté sur TOUTES les extractions d'ID (les deux boucles
#   KEEP_IDS + la boucle de suppression), et 'for run_id in $()' remplacé par
#   'while IFS= read -r' + process substitution (plus robuste, évite le word splitting).
#   Cause: on Git Bash / MSYS2 Windows, 'jq -r' may emit \r\n line endings instead of \n.
#   '$()' strips the trailing \n but NOT \r → ID becomes "12345\r" → KEEP_IDS key is
#   "12345\r" → API URL becomes '.../runs/12345\r' (invalid) → gh api -X DELETE fails
#   silently (hidden by > /dev/null 2>&1).
#   Root fix: '| tr -d '\r'' added on ALL ID extractions (both KEEP_IDS loops + deletion
#   loop), and 'for run_id in $()' replaced with 'while IFS= read -r' + process
#   substitution (more robust, avoids word splitting).
# [FONCTIONNALITÉ 11 — SKIP_MANUAL v4] Ignorer les runs déclenchés manuellement
#   Nouvelle variable SKIP_MANUAL (false par défaut).
#   Si true : les runs dont le champ 'event' vaut 'workflow_dispatch' sont exclus du
#   traitement — elles ne sont ni supprimées ni comptées dans KEEP_OLDEST / KEEP_NEWEST.
#   Ils s'accumulent sans limite ; c'est intentionnel (l'utilisateur veut les conserver).
#   Implémentation : ajout du champ 'event' dans get_all_runs, filtrage dans la boucle
#   principale avant le calcul des KEEP_IDS.
#   New SKIP_MANUAL variable (false by default).
#   If true: runs whose 'event' field equals 'workflow_dispatch' are excluded from
#   processing — they are neither deleted nor counted in KEEP_OLDEST / KEEP_NEWEST.
#   They accumulate without limit; this is intentional (user wants to preserve them).
#   Implementation: 'event' field added in get_all_runs, filtering in the main loop
#   before KEEP_IDS computation.
# [FONCTIONNALITÉ 12 — DELETE_ORPHANED v4] Supprimer tous les runs des workflows orphelins
#   Nouvelle variable DELETE_ORPHANED (false par défaut).
#   Un workflow est considéré "orphelin" si son fichier de config .yml a été supprimé du
#   dépôt : l'API GitHub retourne alors state != "active" (ex: "disabled_manually") ou
#   une réponse vide (workflow complètement introuvable).
#   Si true : TOUTES les runs d'un workflow orphelin sont supprimées, sans tenir compte de
#   KEEP_OLDEST / KEEP_NEWEST. La logique KEEP est court-circuitée via 'continue'.
#   Implémentation : get_workflow_name étendue pour détecter l'état via le même appel API
#   (sans surcoût), résultat stocké dans la variable globale WORKFLOW_IS_ORPHANED.
#   New DELETE_ORPHANED variable (false by default).
#   A workflow is considered "orphaned" if its .yml config file was deleted from the repo:
#   the GitHub API then returns state != "active" (e.g. "disabled_manually") or an empty
#   response (workflow completely not found).
#   If true: ALL runs of an orphaned workflow are deleted, regardless of KEEP_OLDEST /
#   KEEP_NEWEST. The KEEP logic is short-circuited via 'continue'.
#   Implementation: get_workflow_name extended to detect state via the same API call
#   (no extra cost), result stored in global variable WORKFLOW_IS_ORPHANED.
# =========================================================================================================

set -euo pipefail

# ================= CONFIGURATION =================
OWNER="Phoen0x"
REPO="QuelleHeureEst-Il.com"

# Nombre de runs les plus anciens et les plus récents à conserver (par état et par workflow)
# Number of oldest and newest runs to keep (per status and per workflow)
KEEP_OLDEST=10
KEEP_NEWEST=30

# Mode dry-run : true = affiche uniquement, false = supprime réellement
# Dry-run mode: true = display only, false = actually delete
DRY_RUN=false                  # Passe à true pour tester sans supprimer, Passe à false pour supprimer réellement. /  ENG//  Set to false to actually delete.

# États à traiter (laisser vide pour tous les états)
# Statuses to process (leave empty for all statuses)
# États possibles : success, failure, cancelled, skipped, action_required, neutral, timed_out
# Possible statuses: success, failure, cancelled, skipped, action_required, neutral, timed_out
FILTER_STATUS=()               # Exemple / Example : ("success" "failure"), Vide / Empty = tous les états / all states.

# Ignorer les runs déclenchés manuellement via "Run workflow" (event = workflow_dispatch)
# Ignore runs triggered manually via "Run workflow" (event = workflow_dispatch)
# true  = ces runs sont ignorées : ni supprimées, ni comptées dans KEEP_OLDEST / KEEP_NEWEST
# false = tous les runs sont traités normalement (défaut / default)
# true  = these runs are ignored: neither deleted nor counted in KEEP_OLDEST / KEEP_NEWEST
# false = all runs are processed normally (default)
SKIP_MANUAL=true

# Supprimer TOUTES les runs des workflows dont le fichier de config n'existe plus dans le dépôt
# Delete ALL runs from workflows whose config file no longer exists in the repository
# true  = si le workflow est orphelin (state != "active" ou introuvable), TOUTES ses runs sont
#         supprimées, sans tenir compte de KEEP_OLDEST / KEEP_NEWEST
# false = les workflows orphelins sont traités comme les autres (défaut / default)
# true  = if the workflow is orphaned (state != "active" or not found), ALL its runs are
#         deleted regardless of KEEP_OLDEST / KEEP_NEWEST
# false = orphaned workflows are treated like any other (default)
DELETE_ORPHANED=true

# Limite de runs à récupérer par appel API (max GitHub = 100)
# Limit of runs fetched per API call (GitHub max = 100)
PER_PAGE=100

# Délai entre suppressions réelles pour éviter le rate limiting API (en secondes)
# Delay between real deletions to avoid API rate limiting (in seconds)
RATE_LIMIT_DELAY=0.5


# ======================================
# VARIABLES INTERNES NE PAS TOUCHER
# ======================================

# Mise en place de la variable qui sera amenée à être modifiée : Compteur de runs supprimées (réellement ou en dry-run) — doit rester dans le shell courant, ne pas modifier
# Counter of deleted runs (real or dry-run) — must stay in the current shell (not a subshell)
DELETED_COUNT=0

# Indique si le workflow courant est orphelin (plus de fichier .yml actif)
# Internal variable: indicates whether the current workflow is orphaned (no active .yml file)
# Mise à jour par get_workflow_name() à chaque appel / Updated by get_workflow_name() on each call
WORKFLOW_IS_ORPHANED=false


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

# Fonction pour récupérer TOUTES les runs du dépôt (tous workflows, y compris supprimés)
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
    #
    # [FONCTIONNALITÉ 11 — SKIP_MANUAL] Ajout du champ 'event' dans les objets extraits
    #   pour permettre le filtrage des runs workflow_dispatch dans la boucle principale.
    # [FEATURE 11 — SKIP_MANUAL] Added 'event' field to extracted objects to enable
    #   workflow_dispatch run filtering in the main loop.

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
        # Note : 'event' ajouté pour FONCTIONNALITÉ 11 (SKIP_MANUAL)
        # Note: 'event' added for FEATURE 11 (SKIP_MANUAL)
        echo "$raw_page" | jq -c \
            '.workflow_runs[] | {id, created_at, status, conclusion, workflow_id, event}' \
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
# et détecter s'il est orphelin (fichier .yml absent ou workflow désactivé).
# Function to get a workflow's name from its ID (for display purposes)
# and detect whether it is orphaned (missing .yml file or disabled workflow).
#
# [FONCTIONNALITÉ 12 — DELETE_ORPHANED] Cette fonction effectue UN SEUL appel API et
#   en extrait à la fois le nom et le champ 'state'. Si state != "active" ou si la
#   réponse est vide (workflow 404), la variable globale WORKFLOW_IS_ORPHANED est mise
#   à true. Réutiliser le même appel API évite tout surcoût réseau.
# [FEATURE 12 — DELETE_ORPHANED] This function performs ONE API call and extracts both
#   the name and the 'state' field from it. If state != "active" or the response is
#   empty (workflow 404), the global variable WORKFLOW_IS_ORPHANED is set to true.
#   Reusing the same API call avoids any extra network overhead.
get_workflow_name() {
    local workflow_id="$1"
    local api_response name state

    # [CORRECTION 3 — EN-TÊTE API] Ajout de X-GitHub-Api-Version sur tous les appels gh api.
    # [FIX 3 — API HEADER] Added X-GitHub-Api-Version to all gh api calls.
    api_response=$(gh api \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "repos/$OWNER/$REPO/actions/workflows/$workflow_id" 2>/dev/null) || true

    # Extraire le nom et l'état depuis la réponse (vide si 404 ou erreur réseau)
    # Extract name and state from the response (empty if 404 or network error)
    name=$(echo "$api_response"  | jq -r '.name  // empty' 2>/dev/null) || true
    state=$(echo "$api_response" | jq -r '.state // empty' 2>/dev/null) || true

    if [[ -z "$name" ]]; then
        # Workflow complètement introuvable via l'API (supprimé côté GitHub)
        # Workflow completely not found via the API (deleted on GitHub side)
        WORKFLOW_IS_ORPHANED=true
        name="workflow_$workflow_id (supprimé / deleted)"
    elif [[ "$state" != "active" ]]; then
        # Workflow trouvé mais inactif : fichier .yml supprimé du dépôt → désactivé par GitHub
        # Workflow found but inactive: .yml file deleted from repo → disabled by GitHub
        WORKFLOW_IS_ORPHANED=true
        name="$name (inactif·$state / inactive·$state)"
    else
        # Workflow actif, fichier .yml toujours présent dans le dépôt
        # Active workflow, .yml file still present in the repository
        WORKFLOW_IS_ORPHANED=false
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

# Récupérer TOUTES les runs du dépôt (sans passer par la liste des workflows)
# Retrieve ALL repository runs (without going through the workflow list)
echo "🔍 Récupération de TOUTES les runs du dépôt (y compris workflows supprimés)..."
ALL_RUNS=$(get_all_runs)
TOTAL_RUNS=$(echo "$ALL_RUNS" | jq length)

if [[ "$TOTAL_RUNS" -eq 0 ]]; then
    echo "  → Aucun run trouvé."
    exit 0
fi
echo "  → $TOTAL_RUNS runs récupérées."

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

    # [FONCTIONNALITÉ 12 — DELETE_ORPHANED] Réinitialiser WORKFLOW_IS_ORPHANED avant chaque
    #   appel à get_workflow_name, qui va le remettre à jour selon l'état réel du workflow.
    # [FEATURE 12 — DELETE_ORPHANED] Reset WORKFLOW_IS_ORPHANED before each call to
    #   get_workflow_name, which will update it based on the workflow's actual state.
    WORKFLOW_IS_ORPHANED=false
    WORKFLOW_NAME=$(get_workflow_name "$workflow_id")

    echo ""
    echo "📦 Workflow : $WORKFLOW_NAME (ID: $workflow_id) — $TOTAL_RUNS_WF runs"

    # ------------------------------------------------------------------
    # [FONCTIONNALITÉ 12 — DELETE_ORPHANED] Si le workflow est orphelin et
    #   DELETE_ORPHANED=true : supprimer TOUTES ses runs, ignorer KEEP_OLDEST/NEWEST.
    # [FEATURE 12 — DELETE_ORPHANED] If the workflow is orphaned and
    #   DELETE_ORPHANED=true: delete ALL its runs, bypass KEEP_OLDEST/NEWEST.
    # ------------------------------------------------------------------
    if [[ "$DELETE_ORPHANED" == true ]] && [[ "$WORKFLOW_IS_ORPHANED" == true ]]; then
        echo "  🗂️  Workflow orphelin détecté (DELETE_ORPHANED=true) — suppression de TOUS les $TOTAL_RUNS_WF runs"
        while IFS= read -r run_id; do
            process_run "$run_id" "workflow orphelin : $WORKFLOW_NAME — fichier de config absent du dépôt / config file missing from repository"
        done < <(echo "$RUNS_JSON" | jq -r '.[].id' | tr -d '\r')
        # Court-circuit : pas de logique KEEP pour ce workflow
        # Short-circuit: no KEEP logic for this workflow
        continue
    fi

    # ------------------------------------------------------------------
    # [FONCTIONNALITÉ 11 — SKIP_MANUAL] Si SKIP_MANUAL=true : retirer les runs
    #   workflow_dispatch de RUNS_JSON avant tout calcul KEEP_IDS.
    #   Elles ne seront ni supprimées ni prises en compte dans les seuils KEEP.
    # [FEATURE 11 — SKIP_MANUAL] If SKIP_MANUAL=true: remove workflow_dispatch
    #   runs from RUNS_JSON before any KEEP_IDS computation.
    #   They will be neither deleted nor counted toward KEEP thresholds.
    # ------------------------------------------------------------------
    if [[ "$SKIP_MANUAL" == true ]]; then
        manual_count=$(echo "$RUNS_JSON" | jq '[.[] | select(.event == "workflow_dispatch")] | length')
        if [[ "$manual_count" -gt 0 ]]; then
            echo "  ℹ️  $manual_count run(s) manuel(s) (workflow_dispatch) ignoré(s) — SKIP_MANUAL=true"
            RUNS_JSON=$(echo "$RUNS_JSON" | jq '[.[] | select(.event != "workflow_dispatch")]')
            TOTAL_RUNS_WF=$(echo "$RUNS_JSON" | jq length)
        fi
        # Si tous les runs de ce workflow étaient manuels, rien à faire
        # If all runs for this workflow were manual, nothing to do
        if [[ "$TOTAL_RUNS_WF" -eq 0 ]]; then
            echo "  → Aucune run non-manuelle à traiter pour ce workflow."
            continue
        fi
    fi

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

        # Filtrer les runs correspondantes à cet état (conclusion ou status)
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
        # [CORRECTION 10 — CRLF] | tr -d '\r' : strip le \r éventuel émis par jq -r sur Git Bash.
        # [FIX 10 — CRLF] | tr -d '\r' : strip the potential \r emitted by jq -r on Git Bash.
        for ((i=0; i<KEEP_OLDEST && i<COUNT; i++)); do
            id=$(echo "$SORTED" | jq -r ".[$i].id" | tr -d '\r')
            KEEP_IDS["$id"]=1
        done

        # Ajouter les plus récents (en partant de la fin) / Add the most recent (from the end)
        # [CORRECTION 10 — CRLF] | tr -d '\r' : idem, même source jq -r, même risque.
        # [FIX 10 — CRLF] | tr -d '\r' : same source jq -r, same risk.
        for ((i=0; i<KEEP_NEWEST && i<COUNT; i++)); do
            idx=$((COUNT - 1 - i))
            id=$(echo "$SORTED" | jq -r ".[$idx].id" | tr -d '\r')
            KEEP_IDS["$id"]=1
        done

        # Parcourir toutes les runs de cet état et supprimer celles qui ne sont pas dans KEEP_IDS
        # Iterate all runs for this status and delete those not in KEEP_IDS
        #
        # [CORRECTION 10 — CRLF] 'for run_id in $(jq -r ...)' remplacé par
        #   'while IFS= read -r ... < <(jq -r ... | tr -d '\r')' pour deux raisons :
        #   1. tr -d '\r' supprime le \r parasite émis par jq -r sur Git Bash Windows.
        #   2. 'while read' + process substitution est plus robuste que 'for ... in $()' :
        #      pas de word splitting sur les espaces, pas de glob expansion, gère les IDs
        #      contenant des caractères spéciaux (même si improbable ici).
        # [FIX 10 — CRLF] 'for run_id in $(jq -r ...)' replaced with
        #   'while IFS= read -r ... < <(jq -r ... | tr -d '\r')' for two reasons:
        #   1. tr -d '\r' removes the spurious \r emitted by jq -r on Git Bash Windows.
        #   2. 'while read' + process substitution is more robust than 'for ... in $()':
        #      no word splitting on spaces, no glob expansion, handles IDs with special
        #      characters (unlikely here but correct practice).
        while IFS= read -r run_id; do
            if [[ -z "${KEEP_IDS[$run_id]:-}" ]]; then
                process_run "$run_id" "état=$STATE, workflow $WORKFLOW_NAME, ni parmi les $KEEP_OLDEST plus vieux ni les $KEEP_NEWEST plus récents"
            fi
        done < <(echo "$RUNS_STATE" | jq -r '.[].id' | tr -d '\r')
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
echo "   • Runs supprimées : $DELETED_COUNT"
if [[ "$DRY_RUN" == true ]]; then
    echo "   (Mode DRY RUN : aucune suppression réelle)"
else
    echo "   (Mode réel : $DELETED_COUNT runs supprimées)"
fi

echo ""
echo "✅ Opérations terminées (dry-run=$DRY_RUN)."
