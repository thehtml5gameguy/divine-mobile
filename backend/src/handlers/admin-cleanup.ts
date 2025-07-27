// ABOUTME: Admin handler for cleaning up corrupted HTML files from R2 storage
// ABOUTME: Identifies and removes files containing Google login HTML instead of video content

interface CleanupResult {
  mode: 'SCAN' | 'DELETE';
  summary: {
    totalScanned: number;
    corruptedFound: number;
    deleted: number;
    errors: number;
  };
  corruptedFiles: Array<{
    key: string;
    size: number;
    uploaded: string;
    preview: string;
    deleted?: boolean;
    deleteError?: string;
  }>;
  errors: Array<{
    file: string;
    error: string;
  }>;
}

/**
 * Check if content appears to be HTML (Google login page) instead of video
 */
function isGoogleLoginHTML(content: string): boolean {
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
    '<title>Sign in',
    '<meta',
    '<head>'
  ];
  
  const lowerContent = content.toLowerCase();
  return indicators.some(indicator => 
    lowerContent.includes(indicator.toLowerCase())
  );
}

/**
 * Scan R2 bucket for corrupted HTML files masquerading as videos
 */
async function scanForCorruptedFiles(env: Env, deleteFiles: boolean = false): Promise<CleanupResult> {
  const results: CleanupResult = {
    mode: deleteFiles ? 'DELETE' : 'SCAN',
    summary: {
      totalScanned: 0,
      corruptedFound: 0,
      deleted: 0,
      errors: 0
    },
    corruptedFiles: [],
    errors: []
  };

  try {
    console.log(`🔍 Starting ${results.mode} mode scan for corrupted HTML files...`);
    
    // List all files in uploads/ directory
    let cursor: string | undefined = undefined;
    
    do {
      const listed = await env.MEDIA_BUCKET.list({
        prefix: 'uploads/',
        cursor,
        limit: 10 // Reduced batch size to avoid rate limits
      });

      console.log(`📦 Processing batch of ${listed.objects.length} files...`);

      for (const object of listed.objects) {
        results.summary.totalScanned++;
        
        // Skip non-video files based on extension
        if (!object.key.match(/\.(mp4|mov|webm|avi|mkv|m4v)$/i)) {
          continue;
        }

        try {
          // Get the first 2KB of the object to check its content
          const r2Object = await env.MEDIA_BUCKET.get(object.key, {
            range: { offset: 0, length: 2048 }
          });

          if (r2Object) {
            // Read first 2KB as text
            const firstKB = await r2Object.text();
            
            // Check if it's HTML content
            if (isGoogleLoginHTML(firstKB)) {
              console.log(`❌ Found corrupted HTML file: ${object.key}`);
              
              const fileInfo = {
                key: object.key,
                size: object.size,
                uploaded: object.uploaded.toISOString(),
                preview: firstKB.substring(0, 150).replace(/\s+/g, ' ')
              };
              
              results.corruptedFiles.push(fileInfo);
              results.summary.corruptedFound++;
              
              // Delete if requested
              if (deleteFiles) {
                try {
                  await env.MEDIA_BUCKET.delete(object.key);
                  results.summary.deleted++;
                  fileInfo.deleted = true;
                  console.log(`   ✅ Deleted: ${object.key}`);
                } catch (deleteError) {
                  const errorMsg = deleteError instanceof Error ? deleteError.message : String(deleteError);
                  fileInfo.deleteError = errorMsg;
                  results.errors.push({
                    file: object.key,
                    error: errorMsg
                  });
                  results.summary.errors++;
                  console.error(`   ❌ Failed to delete: ${errorMsg}`);
                }
              }
            }
          }
        } catch (error) {
          const errorMsg = error instanceof Error ? error.message : String(error);
          results.errors.push({
            file: object.key,
            error: errorMsg
          });
          results.summary.errors++;
          console.error(`❌ Error checking ${object.key}: ${errorMsg}`);
        }
      }

      cursor = listed.truncated ? listed.cursor : undefined;
    } while (cursor);

    console.log(`✅ Scan complete. Found ${results.summary.corruptedFound} corrupted files out of ${results.summary.totalScanned} scanned.`);

  } catch (error) {
    const errorMsg = error instanceof Error ? error.message : String(error);
    console.error(`❌ Scan failed: ${errorMsg}`);
    throw error;
  }

  return results;
}

/**
 * Handle admin cleanup request
 */
export async function handleAdminCleanup(
  request: Request,
  env: Env
): Promise<Response> {
  try {
    // Check for admin authorization (you should implement proper auth)
    const authHeader = request.headers.get('Authorization');
    if (!authHeader || !authHeader.includes('Bearer')) {
      return new Response(JSON.stringify({
        error: 'Unauthorized',
        message: 'Admin authorization required'
      }), {
        status: 401,
        headers: {
          'Content-Type': 'application/json',
          'Access-Control-Allow-Origin': '*'
        }
      });
    }

    // Parse request to determine mode
    const url = new URL(request.url);
    const mode = url.searchParams.get('mode') || 'scan';
    const deleteFiles = mode === 'delete';

    console.log(`🧹 Admin cleanup request - Mode: ${mode}`);

    // Perform the scan/cleanup
    const results = await scanForCorruptedFiles(env, deleteFiles);

    // Return results
    return new Response(JSON.stringify(results, null, 2), {
      headers: { 
        'Content-Type': 'application/json',
        'Access-Control-Allow-Origin': '*',
        'Cache-Control': 'no-cache'
      }
    });

  } catch (error) {
    console.error('Admin cleanup error:', error);
    return new Response(JSON.stringify({
      error: 'Internal server error',
      message: error instanceof Error ? error.message : 'Cleanup operation failed'
    }), {
      status: 500,
      headers: {
        'Content-Type': 'application/json',
        'Access-Control-Allow-Origin': '*'
      }
    });
  }
}

/**
 * Handle OPTIONS request for admin cleanup endpoint
 */
export function handleAdminCleanupOptions(): Response {
  return new Response(null, {
    status: 204,
    headers: {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'GET, OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type, Authorization',
      'Access-Control-Max-Age': '86400'
    }
  });
}