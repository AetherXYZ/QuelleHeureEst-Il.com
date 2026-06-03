#!/bin/bash
# delete-runs.sh

OWNER="Phoen0x"
REPO="QuelleHeureEst-Il.com"
WORKFLOW_NAME="your-workflow-name"  # Remplacez par le nom du workflow

# Récupérer tous les IDs des workflow runs
RUNS=$(gh run list --repo "$OWNER/$REPO" --workflow "$WORKFLOW_NAME" --json databaseId --jq '.[].databaseId')

# Supprimer chaque run
for RUN_ID in $RUNS; do
  echo "Suppression du run $RUN_ID..."
  gh run delete --repo "$OWNER/$REPO" "$RUN_ID"
done

echo "Tous les runs ont été supprimés!"
