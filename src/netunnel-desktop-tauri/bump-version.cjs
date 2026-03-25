#!/usr/bin/env node

const fs = require('fs').promises
const path = require('path')
// Replace the ESM import with CommonJS require
const packageJson = require('./package.json')

async function updateVersion() {
  // Check if version argument is provided
  const newVersion = process.argv[2]
  if (!newVersion) {
    console.error('Please provide a version number as argument')
    console.error('Usage: node bump-version.js VERSION')
    process.exit(1)
  }

  // Function to update file if it exists
  async function updateFile(filename, searchPattern, replacement) {
    try {
      const filePath = path.join(process.cwd(), filename)
      const fileContent = await fs.readFile(filePath, 'utf8')

      // Create the replacement pattern based on the file type
      const updatedContent = fileContent.replace(searchPattern(), replacement(newVersion))

      if (updatedContent === fileContent) {
        console.log(`Warning: ${filename} version pattern not found`)
        return
      }

      await fs.writeFile(filePath, updatedContent)
      console.log(`Updated ${filename} version to ${newVersion}`)
    } catch (error) {
      if (error.code === 'ENOENT') {
        console.log(`Warning: ${filename} not found`)
      } else {
        console.error(`Error updating ${filename}:`, error.message)
      }
    }
  }

  await updateFile(
    'package.json',
    () => /"version":\s*"[^\"]+"/,
    newVer => `"version": "${newVer}"`
  )

  await updateFile(
    'src-tauri/tauri.conf.json',
    () => /"version":\s*"[^\"]+"/,
    newVer => `"version": "${newVer}"`
  )

  await updateFile(
    'src-tauri/Cargo.toml',
    () => /^version = "[^"]+"/m,
    newVer => `version = "${newVer}"`
  )

  await updateFile(
    'src-tauri/Cargo.lock',
    () => /name = "netunnel"\r?\nversion = "[^"]+"/,
    newVer => `name = "netunnel"\nversion = "${newVer}"`
  )
}

updateVersion().catch(console.error)
