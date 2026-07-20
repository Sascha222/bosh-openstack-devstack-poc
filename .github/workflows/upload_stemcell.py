#!/usr/bin/env python3
"""
Upload BOSH stemcell to Glance with chunked streaming.
Avoids curl's out-of-memory issues with large files.
"""
import sys
import os
import requests
from pathlib import Path

def upload_stemcell(glance_endpoint, auth_token, image_id, image_path):
    """Upload stemcell image to Glance with streaming."""

    url = f"{glance_endpoint}/v2/images/{image_id}/file"

    # CRITICAL: Try WITHOUT Content-Type header first!
    # Some Apache/Glance configs reject explicit Content-Type
    # Glance should auto-detect binary data
    headers = {
        'X-Auth-Token': auth_token,
        # Do NOT set Content-Type - let Glance/Apache auto-detect!
    }

    file_size = os.path.getsize(image_path)
    file_size_mb = file_size / (1024 * 1024)

    print(f"Uploading {image_path}")
    print(f"File size: {file_size_mb:.2f} MB")
    print(f"Upload URL: {url}")
    print(f"Headers: {headers}")
    print("")

    # Open file in binary read mode with streaming
    with open(image_path, 'rb') as f:
        # Stream upload with chunked transfer encoding
        # This reads and sends file in chunks, never loading entire file into memory
        print("Starting chunked upload (no explicit Content-Type)...")

        try:
            response = requests.put(
                url,
                headers=headers,
                data=f,  # Stream from file handle
                timeout=600  # 10 minute timeout
            )

            print(f"\nHTTP Response Code: {response.status_code}")

            if response.status_code in [200, 204]:
                print("✅ Upload successful!")
                return 0
            else:
                print(f"❌ Upload failed!")
                print(f"Response Headers: {dict(response.headers)}")
                print(f"Response Body: {response.text}")

                # If still 415, try WITH Content-Type as last resort
                if response.status_code == 415:
                    print("\n⚠️ Got 415 without Content-Type header")
                    print("Retrying WITH Content-Type: application/octet-stream...")

                    f.seek(0)  # Reset file pointer
                    headers['Content-Type'] = 'application/octet-stream'

                    response2 = requests.put(
                        url,
                        headers=headers,
                        data=f,
                        timeout=600
                    )

                    print(f"Retry HTTP Response Code: {response2.status_code}")

                    if response2.status_code in [200, 204]:
                        print("✅ Upload successful on retry!")
                        return 0
                    else:
                        print(f"❌ Retry also failed: {response2.text}")

                # Check specific error codes
                if response.status_code == 413:
                    print("\n413 Request Entity Too Large - size limit")
                elif response.status_code == 415:
                    print("\n415 Unsupported Media Type - Content-Type issue")
                    print("This is an Apache/Glance configuration problem.")
                    print("DevStack's Apache is rejecting the upload.")

                return 1

        except requests.exceptions.Timeout:
            print("❌ Upload timed out after 10 minutes")
            return 1
        except requests.exceptions.ConnectionError as e:
            print(f"❌ Connection error: {e}")
            return 1
        except Exception as e:
            print(f"❌ Unexpected error: {e}")
            return 1

if __name__ == '__main__':
    if len(sys.argv) != 5:
        print("Usage: upload_stemcell.py <glance_endpoint> <auth_token> <image_id> <image_path>")
        sys.exit(1)

    glance_endpoint = sys.argv[1]
    auth_token = sys.argv[2]
    image_id = sys.argv[3]
    image_path = sys.argv[4]

    sys.exit(upload_stemcell(glance_endpoint, auth_token, image_id, image_path))
