/**
 * AST / Structural Transformation Script for MonsterInsights Plugin
 */
const fs = require('fs');
const path = require('path');

console.log('Running AST/Regex Transformation for MonsterInsights...');

const targetFile = path.resolve(__dirname, '../../submodules/monsterinsights/includes/gutenberg/frontend.php');

if (fs.existsSync(targetFile)) {
  let content = fs.readFileSync(targetFile, 'utf8');
  content = content.replace(/function monsterinsights_is_pro_active\(\)\s*\{\s*return false;/g, 'function monsterinsights_is_pro_active() {\n    return true;');
  fs.writeFileSync(targetFile, content, 'utf8');
  console.log(`Successfully patched Pro license function in ${targetFile}`);
} else {
  console.log(`Target file ${targetFile} not present. Skipping transformation.`);
}
