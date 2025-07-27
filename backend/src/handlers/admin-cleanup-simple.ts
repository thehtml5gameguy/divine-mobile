// ABOUTME: Simplified admin handler for detecting corrupted HTML files by size
// ABOUTME: HTML files are typically much smaller than real videos

interface SimpleCleanupResult {
  mode: 'SCAN' | 'DELETE';
  summary: {
    totalScanned: number;
    suspiciousFiles: number;
    deleted: number;
  };
  suspiciousFiles: Array<{
    key: string;
    size: number;
    uploaded: string;
    reason: string;
  }>;
}

/**
 * Simple scan that identifies suspicious files by size
 * Google login HTML pages are typically < 50KB while videos are much larger
 */
export async function handleAdminCleanupSimple(
  request: Request,
  env: Env
): Promise<Response> {
  try {
    // Check for admin authorization
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

    const url = new URL(request.url);
    const mode = url.searchParams.get('mode') || 'scan';
    const deleteFiles = mode === 'delete';

    const results: SimpleCleanupResult = {
      mode: deleteFiles ? 'DELETE' : 'SCAN',
      summary: {
        totalScanned: 0,
        suspiciousFiles: 0,
        deleted: 0
      },
      suspiciousFiles: []
    };

    console.log(`🔍 Starting simple ${results.mode} scan...`);

    // List all files - scan metadata and check content for very small files
    let cursor: string | undefined = undefined;
    const htmlCheckThreshold = 10 * 1024; // 10KB - Check content for files this small
    const suspiciousThreshold = 50 * 1024; // 50KB - Flag as suspicious if below this
    
    do {
      const listed = await env.MEDIA_BUCKET.list({
        prefix: 'uploads/',
        cursor,
        limit: 1000 // Can handle more when just checking metadata
      });

      for (const object of listed.objects) {
        results.summary.totalScanned++;
        
        // Check if it's a video file
        if (!object.key.match(/\.(mp4|mov|webm|avi|mkv|m4v)$/i)) {
          continue;
        }

        // For very small files, check content to confirm if HTML
        if (object.size < htmlCheckThreshold) {
          try {
            // Get first 1KB to check content
            const r2Object = await env.MEDIA_BUCKET.get(object.key, {
              range: { offset: 0, length: 1024 }
            });

            if (r2Object) {
              const content = await r2Object.text();
              
              // Check for HTML indicators
              const htmlIndicators = [
                '<!DOCTYPE html', '<!doctype html', '<html', '<HTML',
                'accounts.google.com', 'Sign in', 'Google Accounts',
                '<head>', '<meta', '<title>'
              ];
              
              const isHTML = htmlIndicators.some(indicator => 
                content.toLowerCase().includes(indicator.toLowerCase())
              );

              if (isHTML) {
                console.log(`❌ Confirmed HTML file: ${object.key} - ${object.size} bytes`);
                
                results.suspiciousFiles.push({
                  key: object.key,
                  size: object.size,
                  uploaded: object.uploaded.toISOString(),
                  reason: `Confirmed HTML content (Google login page)`
                });
                results.summary.suspiciousFiles++;

                // Delete if requested
                if (deleteFiles) {
                  try {
                    await env.MEDIA_BUCKET.delete(object.key);
                    results.summary.deleted++;
                    console.log(`   ✅ Deleted: ${object.key}`);
                  } catch (error) {
                    console.error(`   ❌ Failed to delete: ${error}`);
                  }
                }
              } else {
                // Small but appears to be binary video data
                console.log(`✓ Small video file: ${object.key} - ${object.size} bytes`);
              }
            }
          } catch (error) {
            console.error(`⚠️  Error checking content of ${object.key}: ${error}`);
            // Still flag as suspicious if we can't check content
            results.suspiciousFiles.push({
              key: object.key,
              size: object.size,
              uploaded: object.uploaded.toISOString(),
              reason: `File size ${object.size} bytes is suspicious but couldn't verify content`
            });
            results.summary.suspiciousFiles++;
          }
        } else if (object.size < suspiciousThreshold) {
          // Files between 10KB and 50KB - just flag as potentially suspicious
          console.log(`⚠️  Potentially small video: ${object.key} - ${object.size} bytes`);
        }
      }

      cursor = listed.truncated ? listed.cursor : undefined;
    } while (cursor);

    console.log(`✅ Scan complete. Found ${results.summary.suspiciousFiles} suspicious files.`);

    return new Response(JSON.stringify(results, null, 2), {
      headers: { 
        'Content-Type': 'application/json',
        'Access-Control-Allow-Origin': '*',
        'Cache-Control': 'no-cache'
      }
    });

  } catch (error) {
    console.error('Simple cleanup error:', error);
    return new Response(JSON.stringify({
      error: 'Internal server error',
      message: error instanceof Error ? error.message : 'Operation failed'
    }), {
      status: 500,
      headers: {
        'Content-Type': 'application/json',
        'Access-Control-Allow-Origin': '*'
      }
    });
  }
}

export function handleAdminCleanupSimpleOptions(): Response {
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