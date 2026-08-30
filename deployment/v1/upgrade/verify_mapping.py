import sys, json, os, datetime

def main():
    channel_json_str = os.environ.get("CHANNEL_JSON", "{}")
    target_version = os.environ.get("TARGET", "")
    legacy_list_path = os.environ.get("LEGACY_ALLOWLIST", "")
    archive_sha256 = os.environ.get("ARCHIVE_SHA256", "")
    
    try:
        channel_data = json.loads(channel_json_str) if channel_json_str.strip() else {}
    except Exception:
        sys.exit(4)
        
    try:
        compose_data = json.load(sys.stdin)
    except Exception:
        sys.exit(4)
        
    services = compose_data.get("services", {})
    if not services:
        sys.exit(4)
        
    releases = channel_data.get("releases", [])
    release = next((r for r in releases if str(r.get("version")).lstrip("vV") == target_version.lstrip("vV")), None)
    if not release:
        sys.exit(4)
        
    channel_name = channel_data.get("channel", "")
    product_name = channel_data.get("product", "")
    
    # Check Legacy
    is_legacy = False
    if channel_name in ["assessment-stable", "hotspot-stable"]:
        try:
            with open(legacy_list_path) as f:
                allowlist = json.load(f)
        except Exception:
            sys.exit(4)
            
        entry = allowlist.get(channel_name, {})
        if entry.get("product") != product_name:
            sys.exit(4)
            
        release_entry = entry.get("releases", {}).get(target_version)
        if release_entry:
            if release_entry.get("archive_sha256") != archive_sha256: sys.exit(4)
            
            expires = release_entry.get("expires_at")
            if expires:
                exp_dt = datetime.datetime.fromisoformat(expires.replace('Z', '+00:00'))
                if datetime.datetime.now(datetime.timezone.utc) > exp_dt:
                    sys.exit(4)
            
            print(f"AUDIT_LOG Legacy policy applied for {channel_name} {target_version}")
            is_legacy = True
        else:
            sys.exit(4)
            
    # Extract images from the release (assuming component channel manifest structure)
    images = release.get("images", {})
    deps = release.get("dependencies", {})
    
    # If the manifest instead uses a 'components' dict (like platform manifest):
    if not images and "components" in release and isinstance(release["components"], dict):
        comp = release["components"].get(product_name, {})
        if comp:
            images = comp.get("images", {})
            deps = comp.get("dependencies", {})

    if is_legacy and not images and not deps:
        # Legacy allowlist bypassing container checks if none provided
        return

    # Strict 1:1 Mapping Check
    manifest_services = set(images.keys()) | set(deps.keys())
    compose_services = set(services.keys())
    
    if manifest_services != compose_services:
        sys.exit(4)
        
    seen_digests = set()
    
    for svc_name, svc_data in services.items():
        img_ref = svc_data.get("image", "")
        # Remove any pinned digest it might already have so we compare the base reference
        img_ref_base = img_ref.split("@")[0]
        
        if svc_name in images:
            expected_digest = images[svc_name].get("digest")
            expected_ref = images[svc_name].get("reference")
            
            if not expected_digest or not expected_ref: sys.exit(4)
            if img_ref_base != expected_ref: sys.exit(4)
            if expected_digest in seen_digests: sys.exit(4)
            seen_digests.add(expected_digest)
            
            print(f"ENFORCE {svc_name} {img_ref_base} {expected_digest}")
        elif svc_name in deps:
            expected_digest = deps[svc_name].get("digest")
            expected_ref = deps[svc_name].get("reference")
            
            if not expected_digest or not expected_ref: sys.exit(4)
            if img_ref_base != expected_ref: sys.exit(4)
            
            print(f"DEPENDENCY {svc_name} {img_ref_base} {expected_digest}")

if __name__ == "__main__":
    main()
