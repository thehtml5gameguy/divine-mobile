#!/usr/bin/env node
// ABOUTME: Script to identify and remove R2 files containing Google login HTML instead of video content
// ABOUTME: Scans R2 bucket for files that start with HTML doctype instead of binary video data

import { config } from 'dotenv';
config();

const CLOUDFLARE_ACCOUNT_ID = process.env.CLOUDFLARE_ACCOUNT_ID;
const CLOUDFLARE_API_TOKEN = process.env.CLOUDFLARE_API_TOKEN || process.env.CLOUDFLARE_API_KEY;
const R2_BUCKET_NAME = 'nostrvine-media';

if (!CLOUDFLARE_ACCOUNT_ID || !CLOUDFLARE_API_TOKEN) {
  console.error('❌ Missing required environment variables:');
  console.error('   CLOUDFLARE_ACCOUNT_ID and CLOUDFLARE_API_TOKEN must be set');
  console.error('   You can set these in a .env file or export them');
  process.exit(1);
}

// Function to list all objects in R2 bucket
async function listR2Objects(prefix = 'uploads/', cursor = null) {
  const url = new URL(`https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}/r2/buckets/${R2_BUCKET_NAME}/objects`);
  url.searchParams.append('prefix', prefix);
  if (cursor) {
    url.searchParams.append('cursor', cursor);
  }
  
  const response = await fetch(url, {
    headers: {
      'Authorization': `Bearer ${CLOUDFLARE_API_TOKEN}`
    }
  });

  if (!response.ok) {
    throw new Error(`Failed to list R2 objects: ${response.status} ${response.statusText}`);
  }

  return response.json();
}

// Function to get object content (first 1KB to check if it's HTML)
async function getObjectHead(key) {
  const url = `https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}/r2/buckets/${R2_BUCKET_NAME}/objects/${encodeURIComponent(key)}`;
  
  const response = await fetch(url, {
    headers: {
      'Authorization': `Bearer ${CLOUDFLARE_API_TOKEN}`,
      'Range': 'bytes=0-1023' // Get first 1KB only
    }
  });

  if (!response.ok) {
    console.warn(`⚠️  Failed to get object ${key}: ${response.status}`);
    return null;
  }

  const buffer = await response.arrayBuffer();
  const text = new TextDecoder('utf-8', { fatal: false }).decode(buffer);
  return text;
}

// Function to delete an object from R2
async function deleteObject(key) {
  const url = `https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}/r2/buckets/${R2_BUCKET_NAME}/objects/${encodeURIComponent(key)}`;
  
  const response = await fetch(url, {
    method: 'DELETE',
    headers: {
      'Authorization': `Bearer ${CLOUDFLARE_API_TOKEN}`
    }
  });

  if (!response.ok) {
    throw new Error(`Failed to delete object ${key}: ${response.status} ${response.statusText}`);
  }

  return response.json();
}

// Check if content looks like HTML (Google login page)
function isGoogleLoginHTML(content) {
  if (!content) return false;
  
  // Check for common HTML indicators and Google-specific content
  const htmlIndicators = [
    '<!DOCTYPE html',
    '<!doctype html',
    '<html',
    '<HTML',
    'accounts.google.com',
    'Sign in - Google Accounts',
    'google.com/signin',
    'ServiceLogin'
  ];
  
  return htmlIndicators.some(indicator => content.includes(indicator));
}

// Main cleanup function
async function cleanupGoogleHTMLFiles(dryRun = true) {
  console.log(`🔍 Scanning R2 bucket for corrupted HTML files...`);
  console.log(`📋 Mode: ${dryRun ? 'DRY RUN (no files will be deleted)' : 'DELETE MODE'}`);
  console.log('');

  let cursor = null;
  let totalScanned = 0;
  let corruptedFiles = [];
  let deletedCount = 0;

  do {
    try {
      const result = await listR2Objects('uploads/', cursor);
      
      if (!result.success || !result.result) {
        console.error('❌ Failed to list objects:', result.errors);
        break;
      }

      const objects = result.result.objects || [];
      console.log(`📦 Processing batch of ${objects.length} files...`);

      for (const obj of objects) {
        totalScanned++;
        
        // Skip if it's not a video file based on extension
        const isVideoFile = obj.key.match(/\.(mp4|mov|webm|avi|mkv|m4v)$/i);
        if (!isVideoFile) {
          continue;
        }

        process.stdout.write(`\r⏳ Checking file ${totalScanned}: ${obj.key}...`);
        
        // Get first 1KB of file content
        const content = await getObjectHead(obj.key);
        
        if (content && isGoogleLoginHTML(content)) {
          process.stdout.write('\r'); // Clear the progress line
          console.log(`\n❌ Found corrupted file: ${obj.key}`);
          console.log(`   Size: ${obj.size} bytes`);
          console.log(`   Uploaded: ${new Date(obj.uploaded).toISOString()}`);
          console.log(`   Preview: ${content.substring(0, 100).replace(/\n/g, ' ')}...`);
          
          corruptedFiles.push({
            key: obj.key,
            size: obj.size,
            uploaded: obj.uploaded
          });

          if (!dryRun) {
            try {
              await deleteObject(obj.key);
              deletedCount++;
              console.log(`   ✅ DELETED`);
            } catch (error) {
              console.error(`   ❌ Failed to delete: ${error.message}`);
            }
          }
        }
        
        // Add small delay to avoid rate limiting
        if (totalScanned % 10 === 0) {
          await new Promise(resolve => setTimeout(resolve, 100));
        }
      }

      cursor = result.result.truncated ? result.result.cursor : null;
    } catch (error) {
      console.error(`\n❌ Error processing batch: ${error.message}`);
      break;
    }
  } while (cursor);

  process.stdout.write('\r'); // Clear the progress line
  console.log('\n');
  console.log('📊 Summary:');
  console.log(`   Total files scanned: ${totalScanned}`);
  console.log(`   Corrupted HTML files found: ${corruptedFiles.length}`);
  if (!dryRun) {
    console.log(`   Files deleted: ${deletedCount}`);
  }

  if (corruptedFiles.length > 0) {
    console.log('\n📋 Corrupted files:');
    corruptedFiles.forEach((file, index) => {
      console.log(`   ${index + 1}. ${file.key} (${file.size} bytes)`);
    });

    if (dryRun) {
      console.log('\n⚠️  This was a DRY RUN. No files were deleted.');
      console.log('   To actually delete these files, run:');
      console.log('   node cleanup-google-html-files.js --delete');
    }
  } else {
    console.log('\n✅ No corrupted HTML files found!');
  }

  return corruptedFiles;
}

// Parse command line arguments
const args = process.argv.slice(2);
const isDryRun = !args.includes('--delete');

// Run the cleanup
cleanupGoogleHTMLFiles(isDryRun)
  .then(() => {
    console.log('\n✅ Cleanup scan complete!');
    process.exit(0);
  })
  .catch(error => {
    console.error('\n❌ Cleanup failed:', error);
    process.exit(1);
  });