
#!/usr/bin/env bash
#
# Run a command or script on your server
#
# Required globals:
#   SSH_USER
#   SERVER
#   COMMAND
#
# Optional globals:
#   EXTRA_ARGS
#   ENV_VARS
#   APPLICATION_NAME
#   DEBUG (default: "false")
#   MODE (default: "deploy")
#   SSH_KEY (default: null)
#   PORT (default: 22)
#   


# Begin Standard 'imports'
set -e
set -o pipefail

# Colors
gray="\\e[37m"
blue="\\e[36m"
red="\\e[31m"
green="\\e[32m"
yellow="\\e[33m"
reset="\\e[0m"

#######################################
# echoes a message in blue
# Globals:
#   None
# Arguments:
#   Message
# Returns:
#   None
#######################################
log_info() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') ${blue}INFO: ${reset} $1"
}

#######################################
# echoes a message in yellow
# Globals:
#   None
# Arguments:
#   Message
# Returns:
#   None
#######################################
log_warn() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') ${yellow}WARN: ${reset} $1"
}

#######################################
# echoes a message in green
# Globals:
#   None
# Arguments:
#   Message
# Returns:
#   None
#######################################
log_success() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') ${green}SUCCESS: ✔${reset} $1"
}

#######################################
# echoes a message in red
# Globals:
#   None
# Arguments:
#   Message
# Returns:
#   None
#######################################
# Set Program Name
PROGNAME=$(basename "$0")

# Custom error handling function
log_error() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') ${red}ERROR ✖${reset} ${PROGNAME}: ${1:-"Unknown Error"}" 1>&2
    exit 1
}

#######################################
# echoes a message in grey. Only if debug mode is enabled
# Globals:
#   DEBUG
# Arguments:
#   Message
# Returns:
#   None
#######################################
enable_debug() {
  if [[ "${DEBUG}" == "true" ]]; then
    info "Enabling debug mode."
    set -x
  fi
}

#######################################
# echoes a message in blue
# Globals:
#   status: Exit status of the command that was executed.
#   output_file: Local path with captured output generated from the command.
# Arguments:
#   command: command to run
# Returns:
#   None
#######################################
run() {
  output_file="/var/tmp/pipe-$(date +%s)-$RANDOM"

  echo "$@"
  set +e
  "$@" | tee "$output_file"
  status=$?
  set -e
}

DEPLOY_SCRIPT="./dokku_deploy.sh"

log_info "Executing Deployment...."

enable_debug

# Declare Variables
SSH_DIR='/home/dokku/.ssh'
DEPLOYMENT_DIR='/home/dokku/.deployments'

# Internal Variables
APPLICATION_DOMAIN_NAME="${DOMAIN_NAME}"
APPLICATION_REPO="git@bitbucket.org:interswitch"
DOCKERFILE_TO_USE="${DOCKERFILE}"
PROJ_DIR="${DEPLOYMENT_DIR}/${PROJECT_DIRECTORY_NAME}"
REPO_URL="${APPLICATION_REPO}/${PROJECT_DIRECTORY_NAME}"
SSH_ACCESS_KEY="${SSH_DIR}/${BITBUCKET_CLONE_KEY_NAME}"


# Image specific variables
DOCKER_USERNAME="${DOCKER_USERNAME}"
DOCKER_PASSWORD="${DOCKER_PASSWORD}"
APP_VERSION="${APP_VERSION}"
BUILD_TAG="${APP_VERSION}.${BITBUCKET_BUILD_NUMBER}"
IMAGE_NAME="${DOCKER_USERNAME}/production:${APPLICATION_NAME}-${BUILD_TAG}"

# Function to add SSH key
function add_ssh_key {
    # Add SSH-Key to ssh-agent
    if ! ssh-add -l > /dev/null 2>&1; then
        log_info "Starting ssh-agent..."
        eval "$(ssh-agent -s)" > /dev/null 2>&1 || log_error "Failed to start ssh-agent"
    else
        log_info "ssh-agent is already running."
    fi

    ssh-add "$SSH_ACCESS_KEY" > /dev/null 2>&1 || log_error "Failed to add SSH key.  \nEnter a BITBUCKET_CLONE_KEY_NAME already added to your bitbucket profile and also located at ~/.ssh in the server"
}

# Function to populate knownhost if missing
function add_to_known_hosts_if_missing {
  local host=$1
  if ssh-keygen -F "$host" > /dev/null; then
    log_info "Host '$host' already exists in known_hosts."
  else
    log_info "Adding '$host' to known_hosts..."
    ssh-keyscan -t ed25519 "$host" >> ~/.ssh/known_hosts
    log_success "Host '$host' added to known_hosts."
  fi
}

# Function to clean up unused images and resources
function cleanup_docker {
    log_info "Cleaning up unused images and resources..."
    docker system prune -af > /dev/null 2>&1 &

    local prune_pid=$!
    while kill -0 $prune_pid 2>/dev/null; do
        echo -n "."
        sleep 1
    done
    echo
    if [[ $? -eq 0 ]]; then
        log_success "Docker cleanup completed"
        else
        log_warn "Docker cleanup encountered some issues"
    fi
}

# Function to check if the app exists
function check_app_exists {

    # Function to create a new Dokku application
    create_app() {
        log_info "Creating $APPLICATION_NAME..."
        dokku apps:create "$APPLICATION_NAME" || log_error "Failed to create application $APPLICATION_NAME"
        log_success "$APPLICATION_NAME created"
    }

    # Function to set domain for the application
    set_app_domain() {
        if [ -n "$APPLICATION_DOMAIN_NAME" ]; then
            dokku domains:set "$APPLICATION_NAME" "$APPLICATION_DOMAIN_NAME" || log_error "Failed to add domain - [$APPLICATION_DOMAIN_NAME] to application [$APPLICATION_NAME]"
            log_success "$APPLICATION_DOMAIN_NAME set to $APPLICATION_NAME"
        else
            log_warn "Domain variable EMPTY. You can set the domain for the application manually using: ${yellow}dokku domains:set <APPLICATION_NAME> <APPLICATION_DOMAIN_NAME> ${reset}"
        fi
    }

    # Main logic to check if the app exists
    if ! dokku apps:list | grep -iq "$APPLICATION_NAME"; then
        log_warn "$APPLICATION_NAME application NOT FOUND!"
        create_app
        set_app_domain
    else
        echo -e "\n--------------------------\nApplication - [$APPLICATION_NAME] already exists.\nProceeding to build...\n--------------------------"
    fi
}

# Function to apply a custom certificate
function enable_ssl {
    use_custom_certificate() {
        if [ -n "$CUSTOM_CERT_FILE" ]; then
            if [ -f "$CUSTOM_CERT_FILE" ]; then
                log_info "Applying ${yellow}custom certificate${reset} to $APPLICATION_DOMAIN_NAME..."
                if dokku certs:add "$APPLICATION_NAME" < "$CUSTOM_CERT_FILE"; then
                    log_success "Custom certificate applied successfully!"
                else
                    log_warn "${red}Error adding custom certificate.${reset}"
                    log_info "Apply manually by running: ${yellow}dokku certs:add <APPLICATION_NAME> <CUSTOM_CERT_FILE>${reset}"
                    log_info "${yellow}Custom certificate file${reset} should contain 'server.crt' and 'server.key'"
                fi
            else
                log_warn "${red}Custom certificate file not found: ${CUSTOM_CERT_FILE}${reset}"
                log_info "Please ensure the file exists and is accessible."
            fi
        fi
    }

    # Function to enable Let's Encrypt certificate
    use_letsencrypt_certificate() {
        log_info "Setting up Let's Encrypt SSL Certificate for $APPLICATION_DOMAIN_NAME..."
        if dokku letsencrypt:enable "$APPLICATION_NAME" "$APPLICATION_DOMAIN_NAME"; then
            log_success "SSL Certificate obtained successfully for $APPLICATION_DOMAIN_NAME"
        else
            log_warn "Failed to add Let's Encrypt to $APPLICATION_NAME"
            log_warn "You can set the domain for the application manually using: ${yellow}dokku domains:set <APPLICATION_NAME> <APPLICATION_DOMAIN_NAME>${reset}"
        fi
    }

    # Function to check if Let's Encrypt plugin is installed
    check_letsencrypt_installed() {
        if ! dokku plugin:list | grep -i "letsencrypt"; then
            log_warn "Let's Encrypt plugin NOT FOUND!"
            log_warn "Install Let's Encrypt plugin by running:"
            log_warn "sudo dokku plugin:install https://github.com/dokku/dokku-letsencrypt.git"
        else
            log_success "Let's Encrypt plugin already installed."
            use_letsencrypt_certificate
        fi
    }

    # Function to handle SSL setup
    if [ -n "$APPLICATION_DOMAIN_NAME" ]; then
        use_custom_certificate
        if [ -z "$CUSTOM_CERT_FILE" ]; then
            check_letsencrypt_installed
        fi
    fi
}
# Function to show app reports and deployment status
function show_app_report() {
        
        # Show report for the app
        dokku ps:report "$APPLICATION_NAME" || log_error "Failed to show app report"

        # Check if the app is running
        if ! docker ps --filter "name=$APPLICATION_NAME" --format "{{.Names}}" | grep -q "$APPLICATION_NAME"; then
            log_error "App is not running"
        else
            echo
            log_info "App ${green}$APPLICATION_NAME${reset} is running"
            docker ps --filter "name=$APPLICATION_NAME"
        fi

        # Deployment status
        echo -e "\n---------------------------------------\n$APPLICATION_NAME Deployment is Successful\n---------------------------------------"

}

# Function to setup deployment environment
function setup_deployment_env() {
        log_info "Deployment run started"

        # Change to the project directory
        cd "$PROJ_DIR" || log_error "Failed to change directory to $PROJ_DIR"

        git config user.email "support@eclathealthcare.com"
        git config user.name "Eclat Bot" 

        # Pull latest changes
        git pull origin $BRANCH || log_error "Failed to pull latest changes"

        # Switch to the deployment branch
        git switch $BRANCH || log_error "Failed to switch to deployment branch"
}

function check_dockerfile_to_use() {
    # Function to build a Docker image using a specified Dockerfile or the default one.
    # Arguments:
    #   $1 - Environment name for the image
    local image_env=$1

    if [[ -n "${DOCKERFILE_TO_USE}" ]]; then
        # Build docker image with custom Dockerfile
        log_info "Building with custom Dockerfile [${yellow}${DOCKERFILE_TO_USE}${reset}] provided..."
        docker build -t "${IMAGE_NAME}" -f "${DOCKERFILE_TO_USE}" . || log_error "Failed to build ${APPLICATION_NAME} image"
    else
        # Build docker image with default Dockerfile
        log_info "Building with default Dockerfile..."
        docker build -t "${IMAGE_NAME}" . || log_error "Failed to build ${APPLICATION_NAME} image"
    fi
    
    log_success "${image_env} image [${green}${IMAGE_NAME}${reset}] built successfully!"
}

# Function to deploy app with latest image
function deploy_with_latest_image() {
        DATE=$(date +%Y.%m.%d-%H:%M)
        NEW_IMAGE_NAME="$APPLICATION_NAME-v1.$DATE"

        log_info "Preparing image for deployment..."
        log_info "Retagging Image for unique deployment run"
        docker tag ${IMAGE_NAME} ${NEW_IMAGE_NAME} || log_error "Failed to retag ${IMAGE_NAME} to ${NEW_IMAGE_NAME}"
        log_info "Current Image Tag - ${green}${NEW_IMAGE_NAME}${reset}."

        # Deploy using the latest image
        log_info "Deploying using the latest image..."
        dokku git:from-image "$APPLICATION_NAME" "$NEW_IMAGE_NAME" || log_error "Failed to deploy $APPLICATION_NAME"
        show_app_report

}

# Function to deploy the app to production environment
function deploy_app_master() {

        log_info "Building Production Image..."

        # Function to check if the app is ready to deploy
    ready_to_deploy() {
        # Login to Image Repository
        echo "${DOCKER_PASSWORD}" | docker login -u "${DOCKER_USERNAME}" --password-stdin >> /dev/null 2>&1
        
        # Setup deployment environment
        setup_deployment_env

        # Check dockerfile to use
        check_dockerfile_to_use "Production"
        
        # Deploy with latest image
        deploy_with_latest_image

        # Push image to repository if successful
        log_info "Pushing Production Image to repository..."
        docker push ${IMAGE_NAME} || log_error "Failed to push $APPLICATION_NAME image"
        log_success "Production image [${green}${IMAGE_NAME}${reset}] pushed successfully!"

        # Optionally export artifacts
       # echo ${IMAGE_NAME} > image_tag.txt
        #echo ${BUILD_TAG} > build_tag.txt
    }
    
        # Function to check the deployment directory
    check_deployment_dir() { 
        if [[ -d $DEPLOYMENT_DIR ]]; then
            cd $DEPLOYMENT_DIR || log_error "Failed to change directory to $DEPLOYMENT_DIR"
            if [[ -n $ALTERNATE_PROJECT_DIRECTORY_NAME ]]; then

                # Define project directory based on ALTERNATE_PROJECT_DIRECTORY_NAME value
                PROJ_DIR="${DEPLOYMENT_DIR}/${ALTERNATE_PROJECT_DIRECTORY_NAME}"
                REPO_URL="${APPLICATION_REPO}/${BITBUCKET_REPO_SLUG}"

                if [[ ! -d ${DEPLOYMENT_DIR}/${ALTERNATE_PROJECT_DIRECTORY_NAME} ]]; then
                    log_warn "Alternate Project Directory $PROJ_DIR NOT FOUND!"
                    log_info "Creating Alternate Project Directory - [ $ALTERNATE_PROJECT_DIRECTORY_NAME ] ..."
                    git clone -b $BRANCH $REPO_URL $ALTERNATE_PROJECT_DIRECTORY_NAME || log_error "Failed to clone $ALTERNATE_PROJECT_DIRECTORY_NAME to $PROJ_DIR"
                    log_success "$APPLICATION_NAME Project Directory created"
                    log_info "Deploying from Alternate Project Directory - [ $ALTERNATE_PROJECT_DIRECTORY_NAME ]"
                    echo
                    ready_to_deploy
                else
                    log_info "Deploying from Alternate Project Directory - [ $ALTERNATE_PROJECT_DIRECTORY_NAME ]"
                    echo
                    ready_to_deploy
                fi               
            elif [[ ! -d $PROJ_DIR || ! -d ${DEPLOYMENT_DIR}/${PROJECT_DIRECTORY_NAME} ]]; then          
                log_warn "Project Directory $PROJ_DIR NOT FOUND!"
                log_info "Creating Project Directory..."
                git clone -b $BRANCH $REPO_URL || log_error "Failed to clone $PROJECT_DIRECTORY_NAME to $PROJ_DIR"
                log_success "$APPLICATION_NAME Project Directory created"
                ready_to_deploy                
            else
                # If project deployment directory exists, proceed to deploy
                ready_to_deploy
            fi
        else
            # Create deployment directory if it doesn't exist
            mkdir -p $DEPLOYMENT_DIR || log_error "Failed to make directory - $DEPLOYMENT_DIR"
            log_success "$DEPLOYMENT_DIR Deployment directory created"
            check_deployment_dir  # Recursive call to recheck the created directory
        fi
    }

    # Start deployment check
    check_deployment_dir
    enable_ssl

}


# Function to deploy the app to lifesaver environment
function deploy_app_lifesaver() {

    # Function to check if the app is ready to deploy
    ready_to_deploy() {

        app_name=${APPLICATION_NAME}
        build_tag="${APP_VERSION}.${BITBUCKET_BUILD_NUMBER}"
        lifesaver_image_name="${DOCKER_USERNAME}/production:${app_name}-${BITBUCKET_REPO_SLUG}-${build_tag}"

        log_info "Building $app_name Production Image..."

        # Login to Image Repository
        echo "${DOCKER_PASSWORD}" | docker login -u "${DOCKER_USERNAME}" --password-stdin >> /dev/null 2>&1
        
        # Setup deployment environment
        setup_deployment_env

        # Check dockerfile to use
        check_dockerfile_to_use "Production"
        
        # Deploy with latest image
        deploy_with_latest_image

        # Retag image to enable push to remote image repository
        docker tag  ${IMAGE_NAME} $lifesaver_image_name
        log_info "Production image - ${green}[ $lifesaver_image_name ] ${reset}"

        # Push image to repository if successful
        log_info "Pushing $app_name Production Image to repository..."
        docker push ${lifesaver_image_name} || log_error "Failed to push $APPLICATION_NAME image"
        log_success "Production image [${green}${lifesaver_image_name}${reset}] pushed successfully!"

        # Optionally export artifacts
       # echo ${lifesaver_image_name} > image_tag.txt
        #echo ${build_tag} > build_tag.txt

    }

        # Function to check the deployment directory
    check_deployment_dir() { 
        if [[ -d $DEPLOYMENT_DIR ]]; then
            cd $DEPLOYMENT_DIR || log_error "Failed to change directory to $DEPLOYMENT_DIR"
            if [[ -n $ALTERNATE_PROJECT_DIRECTORY_NAME ]]; then

                # Define project directory based on ALTERNATE_PROJECT_DIRECTORY_NAME value
                PROJ_DIR="${DEPLOYMENT_DIR}/${ALTERNATE_PROJECT_DIRECTORY_NAME}"
                REPO_URL="${APPLICATION_REPO}/${BITBUCKET_REPO_SLUG}"

                if [[ ! -d ${DEPLOYMENT_DIR}/${ALTERNATE_PROJECT_DIRECTORY_NAME} ]]; then
                    log_warn "Alternate Project Directory $PROJ_DIR NOT FOUND!"
                    log_info "Creating Alternate Project Directory - [ $ALTERNATE_PROJECT_DIRECTORY_NAME ] ..."
                    git clone -b $BRANCH $REPO_URL $ALTERNATE_PROJECT_DIRECTORY_NAME || log_error "Failed to clone $ALTERNATE_PROJECT_DIRECTORY_NAME to $PROJ_DIR"
                    log_success "$APPLICATION_NAME Project Directory created"
                    log_info "Deploying from Alternate Project Directory - [ $ALTERNATE_PROJECT_DIRECTORY_NAME ]"
                    echo
                    ready_to_deploy
                else
                    log_info "Deploying from Alternate Project Directory - [ $ALTERNATE_PROJECT_DIRECTORY_NAME ]"
                    echo
                    ready_to_deploy
                fi               
            elif [[ ! -d $PROJ_DIR || ! -d ${DEPLOYMENT_DIR}/${PROJECT_DIRECTORY_NAME} ]]; then          
                log_warn "Project Directory $PROJ_DIR NOT FOUND!"
                log_info "Creating Project Directory..."
                git clone -b $BRANCH $REPO_URL || log_error "Failed to clone $PROJECT_DIRECTORY_NAME to $PROJ_DIR"
                log_success "$APPLICATION_NAME Project Directory created"
                ready_to_deploy                
            else
                # If project deployment directory exists, proceed to deploy
                ready_to_deploy
            fi
        else
            # Create deployment directory if it doesn't exist
            mkdir -p $DEPLOYMENT_DIR || log_error "Failed to make directory - $DEPLOYMENT_DIR"
            log_success "$DEPLOYMENT_DIR Deployment directory created"
            check_deployment_dir  # Recursive call to recheck the created directory
        fi
    }

    # Start deployment check
    check_deployment_dir
    enable_ssl


}

# Function to deploy the app to other environment
function deploy_app {

    # Function to check if the app is ready to deploy
    ready_to_deploy() {
        # Setup Deployment Environment
        setup_deployment_env

        # Check dockerfile to use
        check_dockerfile_to_use "${BRANCH}"

        # Deploy with latest image
        deploy_with_latest_image

    }

    # Function to check the deployment directory
    check_deployment_dir() { 
        if [[ -d $DEPLOYMENT_DIR ]]; then
            cd $DEPLOYMENT_DIR || log_error "Failed to change directory to $DEPLOYMENT_DIR"
            if [[ -n $ALTERNATE_PROJECT_DIRECTORY_NAME ]]; then

                # Define project directory based on ALTERNATE_PROJECT_DIRECTORY_NAME value
                PROJ_DIR="${DEPLOYMENT_DIR}/${ALTERNATE_PROJECT_DIRECTORY_NAME}"
                REPO_URL="${APPLICATION_REPO}/${BITBUCKET_REPO_SLUG}"

                if [[ ! -d ${DEPLOYMENT_DIR}/${ALTERNATE_PROJECT_DIRECTORY_NAME} ]]; then
                    log_warn "Alternate Project Directory $PROJ_DIR NOT FOUND!"
                    log_info "Creating Alternate Project Directory - [ $ALTERNATE_PROJECT_DIRECTORY_NAME ] ..."
                    git clone -b $BRANCH $REPO_URL $ALTERNATE_PROJECT_DIRECTORY_NAME || log_error "Failed to clone $ALTERNATE_PROJECT_DIRECTORY_NAME to $PROJ_DIR"
                    log_success "$APPLICATION_NAME Project Directory created"
                    log_info "Deploying from Alternate Project Directory - [ $ALTERNATE_PROJECT_DIRECTORY_NAME ]"
                    echo
                    ready_to_deploy
                else
                    log_info "Deploying from Alternate Project Directory - [ $ALTERNATE_PROJECT_DIRECTORY_NAME ]"
                    echo
                    ready_to_deploy
                fi               
            elif [[ ! -d $PROJ_DIR || ! -d ${DEPLOYMENT_DIR}/${PROJECT_DIRECTORY_NAME} ]]; then          
                log_warn "Project Directory $PROJ_DIR NOT FOUND!"
                log_info "Creating Project Directory..."
                git clone -b $BRANCH $REPO_URL || log_error "Failed to clone $PROJECT_DIRECTORY_NAME to $PROJ_DIR"
                log_success "$APPLICATION_NAME Project Directory created"
                ready_to_deploy                
            else
                # If project deployment directory exists, proceed to deploy
                ready_to_deploy
            fi
        else
            # Create deployment directory if it doesn't exist
            mkdir -p $DEPLOYMENT_DIR || log_error "Failed to make directory - $DEPLOYMENT_DIR"
            log_success "$DEPLOYMENT_DIR Deployment directory created"
            check_deployment_dir  # Recursive call to recheck the created directory
        fi
    }

    # Start deployment check
    check_deployment_dir
    enable_ssl
}


function deployment() {
        # Initial setup
        check_app_exists
        add_ssh_key
        # add_to_known_hosts_if_missing bitbucket.org

        # Deployment logic
        if [[ "${BRANCH}" == "master" || "${BRANCH}" == "main" ]]; then
                
                log_info "Source Branch is -${green} ${BRANCH} ${reset}"
                log_info "Proceeding to Production Deployment..."
                deploy_app_master

        elif [[ "${BRANCH}" == "lifesaver" ]]; then
                
                log_info "Source Branch is -${green} ${BRANCH} ${reset}"
                log_info "Proceeding to -${green} ${BRANCH} ${reset}Deployment..."
                deploy_app_lifesaver
        else
                log_info "Source Branch is -${green} ${BRANCH} ${reset}"
                log_info "Proceeding to ${BRANCH} Deployment..."
                deploy_app
        fi

        # Clean up unused resources
        cleanup_docker
}

run deployment

if [[ "${status}" == "0" ]]; then
  log_success "Deployment run finished"
else
  log_error "Failed to complete deployment run"
fi
