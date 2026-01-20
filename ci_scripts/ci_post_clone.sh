#!/bin/sh

# ci_post_clone.sh
# This script runs after Xcode Cloud clones the repository
# It generates Secrets.xcconfig from environment variables

set -e

echo "Generating Secrets.xcconfig from environment variables..."

# Create Secrets.xcconfig from environment variables
cat <<EOF > "$CI_PRIMARY_REPOSITORY_PATH/Secrets.xcconfig"
GEMINI_API_KEY = ${GEMINI_API_KEY}
EOF

echo "Secrets.xcconfig generated successfully"
