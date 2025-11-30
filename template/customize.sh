#!/system/bin/sh

SKIPUNZIP=1

# Module configuration
module_id="org.zrlab.magic_mount"
module_data_dir="/data/adb/magic_mount"
metamodule_link="/data/adb/metamodule"
module_shim_id="meta-mm"

ui_print "- File integrity check"

# Extract all files to temporary directory
if ! unzip -o "${ZIPFILE}" -d "${TMPDIR}" >/dev/null 2>&1; then
    abort "! Failed to extract ZIP file"
fi

# Verify checksums
(
    cd "${TMPDIR}" || abort "! Failed to change directory to TMPDIR"
    
    if [ ! -f "checksums" ]; then
        abort "! checksums file not found in package"
    fi
    
    if sha256sum -c -s "checksums" >/dev/null 2>&1; then
        ui_print "  ✓ File integrity verification passed"
    else
        abort "! File integrity check failed - package may be corrupted"
    fi
) || abort "! Integrity check process failed"

ui_print "- Detecting device architecture..."

# Detect architecture using ro.product.cpu.abi
ABI=$(getprop ro.product.cpu.abi)

if [ -z "$ABI" ]; then
    abort "! Failed to detect device architecture"
fi

ui_print "  Detected ABI: $ABI"

# Select the correct binary based on architecture
case "$ABI" in
    arm64-v8a)
        ui_print "  ✓ Selected architecture: ARM64"
        ARCH_BINARY="mm_arm64"
        ;;
    armeabi-v7a)
        ui_print "  ✓ Selected architecture: ARMv7"
        ARCH_BINARY="mm_armv7"
        ;;
    x86_64)
        ui_print "  ✓ Selected architecture: x86_64"
        ARCH_BINARY="mm_amd64"
        ;;
    *)
        abort "! Unsupported architecture: $ABI"
        ;;
esac

ui_print "- Installing architecture-specific binary"

# Verify the selected binary exists
if [ ! -f "$TMPDIR/bin/$ARCH_BINARY" ]; then
    abort "! Binary not found: $ARCH_BINARY"
fi

# Ensure MODPATH exists
mkdir -p "$MODPATH" || abort "! Failed to create module directory"

# Install the binary
if ! cp "$TMPDIR/bin/$ARCH_BINARY" "$MODPATH/mmd"; then
    abort "! Failed to install binary"
fi

# Set executable permissions
if ! chmod 755 "$MODPATH/mmd"; then
    abort "! Failed to set binary permissions"
fi

ui_print "  ✓ Installed $ARCH_BINARY as magic_mount"

ui_print "- Configuring module properties"

# Modify module.prop with correct module ID and metamodule flag
if ! sed -i "s|^id=.*|id=$module_id|" "$TMPDIR/module.prop"; then
    abort "! Failed to set module ID"
fi

if ! sed -i "s|^metamodule=.*|metamodule=1|" "$TMPDIR/module.prop"; then
    abort "! Failed to set metamodule flag"
fi

ui_print "  ✓ Module ID: $module_id"

ui_print "- Installing module files"

# Define files to install
module_files="
    module.prop
"

# Scripts that need executable permissions
executable_scripts="
    metainstall.sh
    metauninstall.sh
    metamount.sh
    uninstall.sh
"

# Directories to copy recursively
module_dirs="
    webroot
"

# Copy regular module files
for f in ${module_files}; do
    if [ ! -f "$TMPDIR/$f" ]; then
        abort " ! Failed: $f not found"
    fi
    
    if ! cp "$TMPDIR/$f" "$MODPATH/$f"; then
        abort "! Failed to copy $f"
    fi
    
    chmod 0644 "$MODPATH/$f" || abort "! Failed to set permissions for $f"
    ui_print "  ✓ Installed: $f"
done

# Copy executable scripts
for f in ${executable_scripts}; do
    if [ ! -f "$TMPDIR/$f" ]; then
        abort " ! Failed: $f not found"
    fi
    
    if ! cp "$TMPDIR/$f" "$MODPATH/$f"; then
        abort "! Failed to copy $f"
    fi
    
    chmod 0755 "$MODPATH/$f" || abort "! Failed to set permissions for $f"
    ui_print "  ✓ Installed: $f (executable)"
done

# Copy directories
for d in ${module_dirs}; do
    if [ ! -d "$TMPDIR/$d" ]; then
        ui_print "  ! Warning: $d not found, skipping"
        continue
    fi
    
    if ! cp -r "$TMPDIR/$d" "$MODPATH/"; then
        abort "! Failed to copy directory $d"
    fi
    
    ui_print "  ✓ Installed: $d/"
done

ui_print "- Initializing configuration"

# Create data directory
if ! mkdir -p "$module_data_dir"; then
    abort "! Failed to create data directory"
fi

# Install default configuration only if it doesn't exist
if [ ! -f "$module_data_dir/mm.conf" ]; then
    if [ -f "$TMPDIR/mm.conf" ]; then
        if ! cp "$TMPDIR/mm.conf" "$module_data_dir/mm.conf"; then
            abort "! Failed to install default configuration"
        fi
        chmod 0644 "$module_data_dir/mm.conf"
        ui_print "  ✓ Installed default configuration"
    else
        ui_print "  ! Warning: Default config not found"
    fi
else
    ui_print "  ℹ Existing configuration preserved"
fi

# Detect current installation type
ui_print "- Detecting installation type"

current_modid=$(basename "$MODPATH")
modules_dir="/data/adb/modules"
modules_update_dir="/data/adb/modules_update"

if [ "$current_modid" = "$module_shim_id" ]; then
    ui_print "  ⚠ Shim installation detected"
    INSTALL_TYPE="shim"
elif [ "$current_modid" = "$module_id" ]; then
    ui_print "  ✓ Normal installation detected"
    INSTALL_TYPE="normal"
else
    ui_print "  ! Unknown installation type: $current_modid"
    INSTALL_TYPE="unknown"
fi

# Handle shim cleanup for normal installations
if [ "$INSTALL_TYPE" = "normal" ]; then
    ui_print "- Checking for existing shim installation"
    
    shim_removed=0
    
    # Check and remove shim from modules directory
    if [ -d "$modules_dir/$module_shim_id" ]; then
        ui_print "  Found shim in modules directory"
        
        # Verify it's actually a shim by checking module.prop
        if [ -f "$modules_dir/$module_shim_id/module.prop" ]; then
            shim_real_id=$(grep "^id=" "$modules_dir/$module_shim_id/module.prop" | cut -d'=' -f2)
            
            if [ "$shim_real_id" = "$module_id" ]; then
                ui_print "  Removing shim installation: $module_shim_id"
                rm -rf "$modules_dir/$module_shim_id"
                shim_removed=1
            fi
        else
            # No valid module.prop, safe to remove
            ui_print "  Removing invalid shim directory"
            rm -rf "$modules_dir/$module_shim_id"
            shim_removed=1
        fi
    fi
    
    # Check and remove shim from modules_update directory
    if [ -d "$modules_update_dir/$module_shim_id" ]; then
        ui_print "  Found shim in modules_update directory"
        
        if [ -f "$modules_update_dir/$module_shim_id/module.prop" ]; then
            shim_real_id=$(grep "^id=" "$modules_update_dir/$module_shim_id/module.prop" | cut -d'=' -f2)
            
            if [ "$shim_real_id" = "$module_id" ]; then
                ui_print "  Removing shim from updates: $module_shim_id"
                rm -rf "$modules_update_dir/$module_shim_id"
                shim_removed=1
            fi
        else
            ui_print "  Removing invalid shim from updates"
            rm -rf "$modules_update_dir/$module_shim_id"
            shim_removed=1
        fi
    fi
    
    if [ $shim_removed -eq 1 ]; then
        ui_print "  ✓ Shim cleanup completed"
    else
        ui_print "  ℹ No shim installation found"
    fi
fi

ui_print "- Managing metamodule status"

# Check if metamodule symlink exists and points to a different module
if [ -L "$metamodule_link" ]; then
    metamodule_path=$(realpath "$metamodule_link" 2>/dev/null)
    
    if [ -n "$metamodule_path" ]; then
        metamodule_id=$(basename "$metamodule_path")
        
        # Consider both real module_id and shim_id as valid for this module
        if [ "$metamodule_id" != "$module_id" ] && [ "$metamodule_id" != "$module_shim_id" ]; then
            ui_print "  Switching from $metamodule_id to $current_modid"
            
            # Mark old metamodule for removal
            if [ -f "$metamodule_path/module.prop" ]; then
                touch "$metamodule_path/remove" 2>/dev/null
                sed -i "s|^metamodule=.*|metamodule=0|" "$metamodule_path/module.prop" 2>/dev/null
            fi
            
            # Remove old symlink
            rm -f "$metamodule_link"
        elif [ "$metamodule_id" = "$module_shim_id" ] && [ "$current_modid" = "$module_id" ]; then
            # Update link from shim to normal
            ui_print "  Updating metamodule link from shim to normal"
            rm -f "$metamodule_link"
        else
            ui_print "  ✓ Already active metamodule"
        fi
    fi
elif [ -e "$metamodule_link" ]; then
    # If it exists but is not a symlink, remove it
    ui_print "  Cleaning up invalid metamodule link"
    rm -rf "$metamodule_link"
fi

# Create new metamodule symlink if needed
if [ ! -e "$metamodule_link" ]; then
    if ln -sf "$modules_dir/$current_modid" "$metamodule_link"; then
        ui_print "  ✓ Activated as metamodule"
    else
        ui_print "  ! Warning: Failed to create metamodule link"
    fi
fi

# Shim-specific post-install setup
if [ "$INSTALL_TYPE" = "shim" ]; then
    ui_print "- Setting up shim migration"
    ui_print "  Scheduling module ID migration to $module_id"
    
    # Create a post-install script to handle the rename
    cat > "$MODPATH/post-fs-data.sh" << 'EOF'
#!/system/bin/sh

module_id="org.zrlab.magic_mount"
module_shim_id="meta-mm"
metamodule_link="/data/adb/metamodule"
modules_dir="/data/adb/modules"

# Function to safely rename module directory
rename_module() {
    local source_dir="$1"
    local source_id="$2"
    local target_id="$3"
    
    if [ -d "$source_dir/$source_id" ]; then
        # Check if target already exists
        if [ -e "$source_dir/$target_id" ]; then
            # Target exists, check if it's valid
            if [ -f "$source_dir/$target_id/module.prop" ]; then
                target_real_id=$(grep "^id=" "$source_dir/$target_id/module.prop" | cut -d'=' -f2)
                
                if [ "$target_real_id" = "$module_id" ]; then
                    # Valid target module exists, remove shim
                    rm -rf "$source_dir/$source_id"
                    return 0
                fi
            fi
            
            # Invalid target, remove it
            rm -rf "$source_dir/$target_id"
        fi
        
        # Perform rename
        if mv "$source_dir/$source_id" "$source_dir/$target_id"; then
            return 0
        else
            return 1
        fi
    fi
    
    return 2  # Source doesn't exist
}

# Only run once
if [ -f "$modules_dir/$module_id/.shim_migrated" ]; then
    exit 0
fi

# Also check if we're still in shim directory
if [ ! -d "$modules_dir/$module_shim_id" ]; then
    exit 0
fi

# Rename in modules directory
if rename_module "$modules_dir" "$module_shim_id" "$module_id"; then
    # Update metamodule link if it points to shim
    if [ -L "$metamodule_link" ]; then
        link_target=$(readlink "$metamodule_link")
        if [ "$link_target" = "$modules_dir/$module_shim_id" ] || \
           [ "$(basename "$(realpath "$metamodule_link" 2>/dev/null)")" = "$module_shim_id" ]; then
            rm -f "$metamodule_link"
            ln -sf "$modules_dir/$module_id" "$metamodule_link"
        fi
    fi
    
    # Mark migration as complete
    touch "$modules_dir/$module_id/.shim_migrated" 2>/dev/null
fi

# Remove this script after execution
rm -f "$modules_dir/$module_id/post-fs-data.sh"

exit 0
EOF

    chmod 755 "$MODPATH/post-fs-data.sh"
    ui_print "  ✓ Post-install migration script created"
    ui_print "  ℹ Module will be renamed on next boot"
fi

ui_print ""
ui_print "========================================="
ui_print " Magic Mount Installation Information"
ui_print "========================================="
ui_print " Module ID: $module_id"
ui_print " Install Dir: $current_modid"
if [ "$INSTALL_TYPE" = "shim" ]; then
    ui_print " Install Type: Shim (will migrate on reboot)"
else
    ui_print " Install Type: Normal"
fi
ui_print " Architecture: $ABI"
ui_print " Binary: $ARCH_BINARY"
ui_print " Data directory: $module_data_dir"
ui_print "========================================="
ui_print ""

ui_print "- Finalizing installation"

