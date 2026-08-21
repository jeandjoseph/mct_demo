#!/bin/bash

echo "Do you want to configure Azure SQL AI settings? (yes/no)"
read answer

if [[ "$answer" != "yes" ]]; then
    echo "Exiting without configuring."
    exit 0
fi

echo "Logging into Azure..."
az login --output none

echo "Enter your Azure subscription ID:"
read SUBID
az account set --subscription "$SUBID"

echo ""
echo "=== Select Azure OpenAI Resource ==="
az resource list --resource-type "Microsoft.CognitiveServices/accounts" \
    --query "[?kind=='OpenAI'].{name:name,location:location}" -o table

echo "Enter your Azure OpenAI resource name:"
read OPENAI_NAME

echo "Enter the resource group of this Azure OpenAI resource:"
read OPENAI_RG

OPENAI_ENDPOINT=$(az cognitiveservices account show \
    -n "$OPENAI_NAME" -g "$OPENAI_RG" --query "properties.endpoint" -o tsv)

OPENAI_KEY=$(az cognitiveservices account keys list \
    -n "$OPENAI_NAME" -g "$OPENAI_RG" --query "key1" -o tsv)

echo ""
echo "=== Select Azure Cognitive Services (Language) Resource ==="
az resource list --resource-type "Microsoft.CognitiveServices/accounts" \
    --query "[?kind=='TextAnalytics'].{name:name,location:location}" -o table

echo "Enter your Azure Cognitive Services (Language) resource name:"
read LANG_NAME

echo "Enter the resource group of this Language resource:"
read LANG_RG

LANG_ENDPOINT=$(az cognitiveservices account show \
    -n "$LANG_NAME" -g "$LANG_RG" --query "properties.endpoint" -o tsv)

LANG_KEY=$(az cognitiveservices account keys list \
    -n "$LANG_NAME" -g "$LANG_RG" --query "key1" -o tsv)

echo ""
echo "=== Select Azure Translator Resource ==="
az resource list --resource-type "Microsoft.CognitiveServices/accounts" \
    --query "[?kind=='TextTranslation'].{name:name,location:location}" -o table

echo "Enter your Azure Translator resource name:"
read TRANS_NAME

echo "Enter the resource group of this Translator resource:"
read TRANS_RG

TRANS_ENDPOINT=$(az cognitiveservices account show \
    -n "$TRANS_NAME" -g "$TRANS_RG" --query "properties.endpoint" -o tsv)

TRANS_KEY=$(az cognitiveservices account keys list \
    -n "$TRANS_NAME" -g "$TRANS_RG" --query "key1" -o tsv)

TRANS_REGION=$(az cognitiveservices account show \
    -n "$TRANS_NAME" -g "$TRANS_RG" --query "location" -o tsv)

echo ""
echo "=============================================="
echo "Your SQL configuration block is ready to paste"
echo "=============================================="
echo ""

cat <<EOF
-- ============================================
-- Configure