#!/bin/bash
# delete-runs.sh

OWNER="Phoen0x"
REPO="QuelleHeureEst-Il.com"

# Récupérer tous les workflows
WORKFLOWS=$(gh workflow list --repo "$OWNER/$REPO" --json name --jq '.[].name')

for WORKFLOW in $WORKFLOWS; do
  echo "Traitement du workflow: $WORKFLOW"
  
  # Récupérer tous les runs pour ce workflow, triés par date (du plus ancien au plus récent)
  RUNS=$(gh run list --repo "$OWNER/$REPO" --workflow "$WORKFLOW" --json databaseId,createdAt --jq 'sort_by(.createdAt) | .[].databaseId')
  
  # Convertir en tableau
  RUNS_ARRAY=($RUNS)
  TOTAL_RUNS=${#RUNS_ARRAY[@]}
  
  if [ $TOTAL_RUNS -le 2 ]; then
    echo "  → Moins de 3 runs, aucune suppression nécessaire"
    continue
  fi
  
  # Garder le 1er et le dernier, supprimer les autres
  for i in "${!RUNS_ARRAY[@]}"; do
    RUN_ID="${RUNS_ARRAY[$i]}"
    # Si ce n'est pas le premier (index 0) ni le dernier (index TOTAL_RUNS-1)
    if [ $i -gt 0 ] && [ $i -lt $((TOTAL_RUNS - 1)) ]; then
      echo "  → Suppression du run $RUN_ID (index $i)"
      gh run delete --repo "$OWNER/$REPO" "$RUN_ID"
    fi
  done
  
  echo "  → Workflow '$WORKFLOW' traité (gardé: 1er et dernier, supprimé: $((TOTAL_RUNS - 2)) runs)"
done

echo ""
echo "✅ Tous les workflows ont été traités!"
