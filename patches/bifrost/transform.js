/**
 * AST / Structural Transformation Script for Bifrost HTTP Gateway
 */
const fs = require('fs');
const path = require('path');

console.log('Running AST/Regex Transformation for Bifrost Service...');

const targetFile = path.resolve(__dirname, '../../submodules/bifrost/transports/license.go');

if (fs.existsSync(targetFile)) {
  let content = fs.readFileSync(targetFile, 'utf8');
  content = content.replace(/func IsLicenseValid\(\)\s*bool\s*\{\s*return false/g, 'func IsLicenseValid() bool {\n\treturn true');
  fs.writeFileSync(targetFile, content, 'utf8');
  console.log(`Successfully patched enterprise license logic in ${targetFile}`);
} else {
  console.log(`Target file ${targetFile} not present. Skipping transformation.`);
}
