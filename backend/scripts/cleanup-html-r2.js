// ABOUTME: Worker script to identify and clean corrupted HTML files from R2
// ABOUTME: Deploy this as a one-time worker to scan and remove Google login HTML files

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    
    // Only allow specific actions
    if (url.pathname === '/cleanup-scan') {
      return await scanForCorruptedFiles(env, false);
    } else if (url.pathname === '/cleanup-delete') {
      return await scanForCorruptedFiles(env, true);
    }
    
    return new Response('Available endpoints:\n/cleanup-scan - Scan for corrupted files (dry run)\n/cleanup-delete - Delete corrupted files', {
      status: 200,
      headers: { 'Content-Type': 'text/plain' }
    });
  }
};

async function scanForCorruptedFiles(env, deleteFiles = false) {
  const results = {
    totalScanned: 0,
    corruptedFiles: [],
    deletedFiles: [],
    errors: []
  };

  try {
    // List all files in uploads/ directory
    let cursor = undefined;
    
    do {
      const listed = await env.MEDIA_BUCKET.list({
        prefix: 'uploads/',
        cursor,
        limit: 100
      });

      for (const object of listed.objects) {
        results.totalScanned++;
        
        // Skip non-video files
        if (!object.key.match(/\.(mp4|mov|webm|avi|mkv|m4v)$/i)) {
          continue;
        }

        try {
          // Get the object to check its content
          const r2Object = await env.MEDIA_BUCKET.get(object.key, {
            range: { offset: 0, length: 1024 } // Only get first 1KB
          });

          if (r2Object) {
            // Read first 1KB as text
            const firstKB = await r2Object.text();
            
            // Check if it's HTML content
            if (isGoogleLoginHTML(firstKB)) {
              const fileInfo = {
                key: object.key,
                size: object.size,
                uploaded: object.uploaded.toISOString(),
                preview: firstKB.substring(0, 100).replace(/\s+/g, ' ')
              };
              
              results.corruptedFiles.push(fileInfo);
              
              // Delete if requested
              if (deleteFiles) {
                try {
                  await env.MEDIA_BUCKET.delete(object.key);
                  results.deletedFiles.push(object.key);
                  fileInfo.deleted = true;
                } catch (deleteError) {
                  fileInfo.deleteError = deleteError.message;
                  results.errors.push({
                    file: object.key,
                    error: deleteError.message
                  });
                }
              }
            }
          }
        } catch (error) {
          results.errors.push({
            file: object.key,
            error: error.message
          });
        }
      }

      cursor = listed.truncated ? listed.cursor : undefined;
    } while (cursor);

  } catch (error) {
    results.error = error.message;
  }

  // Format response
  const response = {
    mode: deleteFiles ? 'DELETE' : 'SCAN',
    summary: {
      totalScanned: results.totalScanned,
      corruptedFound: results.corruptedFiles.length,
      deleted: results.deletedFiles.length,
      errors: results.errors.length
    },
    corruptedFiles: results.corruptedFiles,
    errors: results.errors
  };

  return new Response(JSON.stringify(response, null, 2), {
    headers: { 
      'Content-Type': 'application/json',
      'Cache-Control': 'no-cache'
    }
  });
}

function isGoogleLoginHTML(content) {
  if (!content) return false;
  
  // Check for HTML doctype or Google login indicators
  const indicators = [
    '<!DOCTYPE html',
    '<!doctype html',
    '<html',
    '<HTML',
    'accounts.google.com',
    'Sign in',
    'Google Accounts',
    'google.com',
    'ServiceLogin',
    '<title>Sign in'
  ];
  
  return indicators.some(indicator => 
    content.toLowerCase().includes(indicator.toLowerCase())
  );
}