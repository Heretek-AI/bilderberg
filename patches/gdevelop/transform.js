/**
 * AST / Structural Transformation Script for GDevelop AI Module
 * Fallback engine invoked when unified diff patching encounters upstream line drift.
 */
const fs = require('fs');
const path = require('path');

console.log('Running AST/Regex Transformation for GDevelop AI services...');

const targetFile = path.resolve(__dirname, '../../submodules/gdevelop/newIDE/app/src/AI/AIService.js');

if (fs.existsSync(targetFile)) {
  let content = fs.readFileSync(targetFile, 'utf8');
  const targetSnippet = "return 'https://api.gdevelop.io/ai';";
  const replacementSnippet = "const customEndpoint = process.env.CUSTOM_AI_ENDPOINT || window.CUSTOM_AI_ENDPOINT;\n  return customEndpoint || 'https://api.gdevelop.io/ai';";

  if (content.includes(targetSnippet)) {
    content = content.replace(targetSnippet, replacementSnippet);
    fs.writeFileSync(targetFile, content, 'utf8');
    console.log(`Successfully injected custom AI endpoint logic into ${targetFile}`);
  } else {
    console.log(`Target snippet not found in ${targetFile}. Content may already be modified or altered.`);
  }
} else {
  console.log(`Target file ${targetFile} not present. Skipping AST transformation.`);
}
