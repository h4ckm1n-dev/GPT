#!/bin/bash

# Fetch the transfer method from script argument
transfer_method=$1

# Set the source file and destination paths
source_dir="/var/log/broadpeak/bks350/support-package/"
destination_scp1="supportbpk@10.3.3.7:~/log_storage/vod"
destination_scp2="supportbpk@10.3.3.8:~/log_storage/vod"
destination_s3_1="s3://broadpeak/log_exporter/bucket1/"
destination_s3_2="s3://broadpeak/log_exporter/bucket2/"

# Set the S3 endpoint URL
s3_endpoint="http://magentatv.com"

# Define log file path
log_file="/var/log/log_exporter/cron.json"

# Maximum attempts to transfer a file
max_attempts=3

# Transferred files list
transferred_files_list="/var/log/log_exporter/transfert_hist.json"

# Create log folder if it doesn't exist
log_folder="/var/log/log_exporter"
if [ ! -d "$log_folder" ]; then
  mkdir -p "$log_folder"
fi

# Check for user input
if [ $# -eq 0 ]; then
    echo "No arguments provided. Please specify '-scp' or '-s3' as the argument."
    exit 1
elif [ $1 == '-scp' ]; then
    transfer_func=transfer_files_scp
elif [ $1 == '-s3' ]; then
    transfer_func=transfer_files_s3
else
    echo "Invalid argument. Please specify '-scp' or '-s3'."
    exit 1
fi

log() {
    local type=$1
    shift
    local message=$@

    local status
    if [ "$type" == "Error" ]; then
        status=2
    elif [ "$type" == "Warning" ]; then
        status=1
    elif [ "$type" == "Info" ]; then
        status=0
    else
        echo "Invalid type: $type"
        return
    fi

    local hostname=$(hostname)

    log_message=$(python3 -c "import json, datetime; print(json.dumps({'timestamp': str(datetime.datetime.now()), 'type': '${type}', 'message': '${message}', 'status': ${status}, 'hostname': '${hostname}'}))")

    echo "${log_message}" >> "${log_file}"
}

get_last_status() {
    python3 -c "
import json
with open('${log_file}', 'r') as f:
    lines = f.readlines()
    last_line = lines[-1] if lines else None
    if last_line:
        log_entry = json.loads(last_line)
        print(log_entry.get('status', ''))
    "
}

transfer_files_scp() {
    local source=$1
    local destination=$2
    local filename=$(basename "${source}")
    local dst_path="${destination%%:*}:${destination#*:}/${filename}"

    local src_checksum=$(sha256sum "${source}" | awk '{ print $1 }')

    for ((i=1; i<=max_attempts; i++)); do
        log "Info" "Transferring file to ${dst_path} (Attempt $i)..."
        scp_output=$(scp "${source}" "${dst_path}" 2>&1)

        if [ $? -eq 0 ]; then
            local dst_checksum=$(ssh ${destination%%:*} "sha256sum ${destination#*:}/${filename}" | awk '{ print $1 }')

            if [ "$src_checksum" == "$dst_checksum" ]; then
                log "Info" "File transfer to ${dst_path} completed."
                log "Info" "Checksum verification for ${dst_path} succeeded."
                log "Info" "$scp_output"

                local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
                echo "{\"timestamp\": \"${timestamp}\", \"file\": \"${source}\", \"destination\": \"${dst_path}\"}" >> "${transferred_files_list}"
                return 0
            else
                log "Warning" "Checksum mismatch for ${dst_path}. Retrying transfer..."
                continue
            fi
        else
            log "Warning" "File transfer to ${dst_path} failed. Retrying..."
            log "Error" "$scp_output"
            continue
        fi
    done

    log "Error" "File transfer to ${dst_path} failed after ${max_attempts} attempts."
    return 1
}

transfer_files_s3() {
    local source=$1
    local destination=$2

    local src_checksum=$(sha256sum "${source}" | awk '{ print $1 }')

    for ((i=1; i<=max_attempts; i++)); do
        log "Info" "Uploading file to ${destination} (Attempt $i)..."

        s3_output=$(aws s3 cp "${source}" "${destination}" --region "${aws_region}" --profile "${aws_profile}" --endpoint-url "$s3_endpoint" 2>&1)

        if [ $? -eq 0 ]; then
            local dst_checksum=$(aws s3api head-object --bucket "${destination#*:}" --key "$(basename "${source}")" --query 'ETag' --output text --region "${aws_region}" --profile "${aws_profile}" --endpoint-url "$s3_endpoint" | tr -d '"')

            if [ "$src_checksum" == "$dst_checksum" ]; then
                log "Info" "File upload to ${destination} completed."
                log "Info" "Checksum verification for ${destination} succeeded."
                log "Info" "$s3_output"

                local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
                echo "{\"timestamp\": \"${timestamp}\", \"file\": \"${source}\", \"destination\": \"${destination}\"}" >> "${transferred_files_list}"
                return 0
            else
                log "Warning" "Checksum mismatch for ${destination}. Retrying upload..."
                continue
            fi
        else
            log "Warning" "File upload to ${destination} failed. Retrying..."
            log "Error" "$s3_output"
            continue
        fi
    done

    log "Error" "File upload to ${destination} failed after ${max_attempts} attempts."
    return 1
}


last_status=$(get_last_status)

if [ "${last_status}" == "2" ]; then
    log "Info" "[Retry] The last operation ended in Error. Re-attempting file transfer..."

    last_file_time=$(tail -n 1 ${transferred_files_list} | python3 -c 'import json,sys; print(json.load(sys.stdin)["timestamp"])')

    new_files=$(find ${source_dir} -name '*.tar.gz' -newermt "${last_file_time}")

    if [ -z "$new_files" ]; then
        log "Error" "[Retry] No new tar.gz log to transfer. Check BKS350_support.py execution."
        exit 1
    fi

    for file in $new_files; do
        if $transfer_func "${file}" "${destination_scp1}"; then
            verified1=true
        else
            log "Error" "[Retry] Aborting due to failed file transfer to ${destination_scp1}."
            exit 1
        fi

        if $transfer_func "${file}" "${destination_scp2}"; then
            verified2=true
        else
            log "Error" "[Retry] Aborting due to failed file transfer to ${destination_scp2}."
            exit 1
        fi

        # Write to transferred_files_list only when both destinations are verified
        if [ "$verified1" = true ] && [ "$verified2" = true ]; then
            # Add source file and destination to the transferred files list
            local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")  # Use ISO 8601 timestamp format
            echo "{\"timestamp\": \"${timestamp}\", \"file\": \"${file}\", \"destination\": \"${destination_scp1}\"}" >> "${transferred_files_list}"
            echo "{\"timestamp\": \"${timestamp}\", \"file\": \"${file}\", \"destination\": \"${destination_scp2}\"}" >> "${transferred_files_list}"
            
            # Delete the source file after both SCP destinations are completed
            rm "${file}"
            log "Info" "Source file ${file} deleted."
        fi
    done
else
    log "Info" "[Retry] The last operation completed successfully. No need to re-attempt file transfer."
fi
