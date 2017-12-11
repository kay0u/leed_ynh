#!/bin/bash

#=================================================
# BACKUP
#=================================================

HUMAN_SIZE () {	# Transforme une taille en Ko en une taille lisible pour un humain
	human=$(numfmt --to=iec --from-unit=1K $1)
	echo $human
}

CHECK_SIZE () {	# Vérifie avant chaque backup que l'espace est suffisant
	file_to_analyse=$1
	backup_size=$(du --summarize "$file_to_analyse" | cut -f1)
	free_space=$(df --output=avail "/home/yunohost.backup" | sed 1d)

	if [ $free_space -le $backup_size ]
	then
		ynh_print_err "Espace insuffisant pour sauvegarder $file_to_analyse."
		ynh_print_err "Espace disponible: $(HUMAN_SIZE $free_space)"
		ynh_die "Espace nécessaire: $(HUMAN_SIZE $backup_size)"
	fi
}

#=================================================
# PACKAGE CHECK BYPASSING...
#=================================================

IS_PACKAGE_CHECK () {	# Détermine une exécution en conteneur (Non testé)
	return $(uname -n | grep -c 'pchecker_lxc')
}

#=================================================
# EXPERIMENTAL HELPERS
#=================================================

# INFOS
# n (Node version management) utilise la variable PATH pour stocker le path de la version de node à utiliser.
# C'est ainsi qu'il change de version
# ynh_install_nodejs installe la version de nodejs demandée en argument, avec n
# ynh_use_nodejs active une version de nodejs dans le script courant
# 3 variables sont mises à disposition, et 2 sont stockées dans la config de l'app
# - nodejs_path: Le chemin absolu de cette version de node
# Utilisé pour des appels directs à node.
# - nodejs_version: Simplement le numéro de version de nodejs pour cette application
# - nodejs_use_version: Un alias pour charger une version de node dans le shell courant.
# Utilisé pour démarrer un service ou un script qui utilise node ou npm
# Dans ce cas, c'est $PATH qui contient le chemin de la version de node. Il doit être propagé sur les autres shell si nécessaire.

n_install_dir="/opt/node_n"
node_version_path="/opt/node_n/n/versions/node"
# N_PREFIX est le dossier de n, il doit être chargé dans les variables d'environnement pour n.
export N_PREFIX="$n_install_dir"

ynh_install_n () {
	echo "Installation of N - Node.js version management" >&2
	# Build an app.src for n
	mkdir -p "../conf"
	echo "SOURCE_URL=https://github.com/tj/n/archive/v2.1.7.tar.gz
SOURCE_SUM=2ba3c9d4dd3c7e38885b37e02337906a1ee91febe6d5c9159d89a9050f2eea8f" > "../conf/n.src"
	# Download and extract n
	ynh_setup_source "$n_install_dir/git" n
	# Install n
	(cd "$n_install_dir/git"
	PREFIX=$N_PREFIX make install 2>&1)
}

ynh_use_nodejs () {
	nodejs_version=$(ynh_app_setting_get $app nodejs_version)

	load_n_path="[[ :$PATH: == *\":$n_install_dir/bin:\"* ]] || PATH=\"$n_install_dir/bin:$PATH\"; N_PREFIX="$n_install_dir""

	nodejs_use_version="$n_install_dir/bin/n -q $nodejs_version"

	# "Load" a version of node
	eval $load_n_path; $nodejs_use_version

	# Get the absolute path of this version of node
	nodejs_path="$(n bin $nodejs_version)"

	# Make an alias for node use
	ynh_node_exec="eval $load_n_path; n use $nodejs_version"
}

ynh_install_nodejs () {
	# Use n, https://github.com/tj/n to manage the nodejs versions
	nodejs_version="$1"
	local n_install_script="https://git.io/n-install"

	# Create $n_install_dir
	mkdir -p "$n_install_dir"

	# Load n path in PATH
	CLEAR_PATH="$n_install_dir/bin:$PATH"
	# Remove /usr/local/bin in PATH in case of node has already setup.
	PATH=$(echo $CLEAR_PATH | sed 's@/usr/local/bin:@@')

	# Move an existing node binary, to avoid to block n.
	test -x /usr/bin/node && mv /usr/bin/node /usr/bin/node_n
	test -x /usr/bin/npm && mv /usr/bin/npm /usr/bin/npm_n

	# If n is not previously setup, install it
	if ! test n --version > /dev/null 2>&1
	then
		ynh_install_n
	fi

	# Modify the default N_PREFIX in n script
	ynh_replace_string "^N_PREFIX=\${N_PREFIX-.*}$" "N_PREFIX=\${N_PREFIX-$N_PREFIX}" "$n_install_dir/bin/n"

	# Restore /usr/local/bin in PATH
	PATH=$CLEAR_PATH

	# And replace the old node binary.
	test -x /usr/bin/node_n && mv /usr/bin/node_n /usr/bin/node
	test -x /usr/bin/npm_n && mv /usr/bin/npm_n /usr/bin/npm

	# Install the requested version of nodejs
	n $nodejs_version

	# Find the last "real" version for this major version of node.
	real_nodejs_version=$(find $node_version_path/$nodejs_version* -maxdepth 0 | sort --version-sort | tail --lines=1)
	real_nodejs_version=$(basename $real_nodejs_version)

	# Create a symbolic link for this major version. If the file doesn't already exist
	if [ ! -e "$node_version_path/$nodejs_version" ]
	then
		ln --symbolic --force --no-target-directory $node_version_path/$real_nodejs_version $node_version_path/$nodejs_version
	fi

	# Store the ID of this app and the version of node requested for it
	echo "$YNH_APP_ID:$nodejs_version" | tee --append "$n_install_dir/ynh_app_version"

	# Store nodejs_version into the config of this app
	ynh_app_setting_set $app nodejs_version $nodejs_version

	# Build the update script and set the cronjob
	ynh_cron_upgrade_node

	ynh_use_nodejs
}

ynh_remove_nodejs () {
	ynh_use_nodejs

	# Remove the line for this app
	sed --in-place "/$YNH_APP_ID:$nodejs_version/d" "$n_install_dir/ynh_app_version"

	# If none another app uses this version of nodejs, remove it.
	if ! grep --quiet "$nodejs_version" "$n_install_dir/ynh_app_version"
	then
		n rm $nodejs_version
	fi

	# If none another app uses n, remove n
	if [ ! -s "$n_install_dir/ynh_app_version" ]
	then
		ynh_secure_remove "$n_install_dir"
		ynh_secure_remove "/usr/local/n"
		sed --in-place "/N_PREFIX/d" /root/.bashrc
	fi
}

ynh_cron_upgrade_node () {
	# Build the update script
	cat > "$n_install_dir/node_update.sh" << EOF
#!/bin/bash

version_path="$node_version_path"
n_install_dir="$n_install_dir"

# Log the date
date

# List all real installed version of node
all_real_version="\$(find \$version_path/* -maxdepth 0 -type d | sed "s@\$version_path/@@g")"

# Keep only the major version number of each line
all_real_version=\$(echo "\$all_real_version" | sed 's/\..*\$//')

# Remove double entries
all_real_version=\$(echo "\$all_real_version" | sort --unique)

# Read each major version
while read version
do
	echo "Update of the version \$version"
	sudo \$n_install_dir/bin/n \$version

	# Find the last "real" version for this major version of node.
	real_nodejs_version=\$(find \$version_path/\$version* -maxdepth 0 | sort --version-sort | tail --lines=1)
	real_nodejs_version=\$(basename \$real_nodejs_version)

	# Update the symbolic link for this version
	sudo ln --symbolic --force --no-target-directory \$version_path/\$real_nodejs_version \$version_path/\$version
done <<< "\$(echo "\$all_real_version")"
EOF

	chmod +x "$n_install_dir/node_update.sh"

	# Build the cronjob
	cat > "/etc/cron.daily/node_update" << EOF
#!/bin/bash

$n_install_dir/node_update.sh >> $n_install_dir/node_update.log
EOF

	chmod +x "/etc/cron.daily/node_update"
}

#=================================================

# Start or restart a service and follow its booting
#
# usage: ynh_check_starting "Line to match" [Log file] [Timeout]
#
# | arg: Line to match - The line to find in the log to attest the service have finished to boot.
# | arg: Log file - The log file to watch
# /var/log/$app/$app.log will be used if no other log is defined.
# | arg: Timeout - The maximum time to wait before ending the watching. Defaut 300 seconds.
ynh_check_starting () {
	local line_to_match="$1"
	local app_log="${2:-/var/log/$app/$app.log}"
	local timeout=${3:-300}

	ynh_clean_check_starting () {
		# Stop the execution of tail.
		kill -s 15 $pid_tail 2>&1
		ynh_secure_remove "$templog" 2>&1
	}

	echo "Starting of $app" >&2
	systemctl restart $app
	local templog="$(mktemp)"
	# Following the starting of the app in its log
	tail -f -n1 "$app_log" > "$templog" &
	# Get the PID of the tail command
	local pid_tail=$!

	local i=0
	for i in `seq 1 $timeout`
	do
		# Read the log until the sentence is found, that means the app finished to start. Or run until the timeout
		if grep --quiet "$line_to_match" "$templog"
		then
			echo "The service $app has correctly started." >&2
			break
		fi
		echo -n "." >&2
		sleep 1
	done
	if [ $i -eq $timeout ]
	then
		echo "The service $app didn't fully started before the timeout." >&2
	fi

	echo ""
	ynh_clean_check_starting
}

#=================================================

ynh_print_log () {
  echo "${1}"
}

# Print an info on stdout
#
# usage: ynh_print_info "Text to print"
# | arg: text - The text to print
ynh_print_info () {
  ynh_print_log "[INFO] ${1}"
}

# Print a warning on stderr
#
# usage: ynh_print_warn "Text to print"
# | arg: text - The text to print
ynh_print_warn () {
  ynh_print_log "[WARN] ${1}" >&2
}

# Print a error on stderr
#
# usage: ynh_print_err "Text to print"
# | arg: text - The text to print
ynh_print_err () {
  ynh_print_log "[ERR] ${1}" >&2
}

# Execute a command and print the result as an error
#
# usage: ynh_exec_err command to execute
# usage: ynh_exec_err "command to execute | following command"
# In case of use of pipes, you have to use double quotes. Otherwise, this helper will be executed with the first command, then be send to the next pipe.
#
# | arg: command - command to execute
ynh_exec_err () {
	ynh_print_err "$(eval $@)"
}

# Execute a command and print the result as a warning
#
# usage: ynh_exec_warn command to execute
# usage: ynh_exec_warn "command to execute | following command"
# In case of use of pipes, you have to use double quotes. Otherwise, this helper will be executed with the first command, then be send to the next pipe.
#
# | arg: command - command to execute
ynh_exec_warn () {
	ynh_print_warn "$(eval $@)"
}

# Execute a command and force the result to be printed on stdout
#
# usage: ynh_exec_warn_less command to execute
# usage: ynh_exec_warn_less "command to execute | following command"
# In case of use of pipes, you have to use double quotes. Otherwise, this helper will be executed with the first command, then be send to the next pipe.
#
# | arg: command - command to execute
ynh_exec_warn_less () {
	eval $@ 2>&1
}

# Execute a command and redirect stdout in /dev/null
#
# usage: ynh_exec_quiet command to execute
# usage: ynh_exec_quiet "command to execute | following command"
# In case of use of pipes, you have to use double quotes. Otherwise, this helper will be executed with the first command, then be send to the next pipe.
#
# | arg: command - command to execute
ynh_exec_quiet () {
	eval $@ > /dev/null
}

# Execute a command and redirect stdout and stderr in /dev/null
#
# usage: ynh_exec_fully_quiet command to execute
# usage: ynh_exec_fully_quiet "command to execute | following command"
# In case of use of pipes, you have to use double quotes. Otherwise, this helper will be executed with the first command, then be send to the next pipe.
#
# | arg: command - command to execute
ynh_exec_fully_quiet () {
	eval $@ > /dev/null 2>&1
}

#=================================================

# Install or update the main directory yunohost.multimedia
#
# usage: ynh_multimedia_build_main_dir
ynh_multimedia_build_main_dir () {
	wget -nv https://github.com/YunoHost-Apps/yunohost.multimedia/archive/master.zip 2>&1
	unzip -q master.zip
	./yunohost.multimedia-master/script/ynh_media_build.sh
}

# Add a directory in yunohost.multimedia
# This "directory" will be a symbolic link to a existing directory.
#
# usage: ynh_multimedia_addfolder "Source directory" "Destination directory"
#
# | arg: Source directory - The real directory which contains your medias.
# | arg: Destination directory - The name and the place of the symbolic link, relative to "/home/yunohost.multimedia"
ynh_multimedia_addfolder () {
	local source_dir="$1"
	local dest_dir="$2"
	./yunohost.multimedia-master/script/ynh_media_addfolder.sh --source="$source_dir" --dest="$dest_dir"
}

# Move a directory in yunohost.multimedia, and replace by a symbolic link
#
# usage: ynh_multimedia_movefolder "Source directory" "Destination directory"
#
# | arg: Source directory - The real directory which contains your medias.
# It will be moved to "Destination directory"
# A symbolic link will replace it.
# | arg: Destination directory - The new name and place of the directory, relative to "/home/yunohost.multimedia"
ynh_multimedia_movefolder () {
	local source_dir="$1"
	local dest_dir="$2"
	./yunohost.multimedia-master/script/ynh_media_addfolder.sh --inv --source="$source_dir" --dest="$dest_dir"
}

# Allow an user to have an write authorisation in multimedia directories
#
# usage: ynh_multimedia_addaccess user_name
#
# | arg: user_name - The name of the user which gain this access.
ynh_multimedia_addaccess () {
	local user_name=$1
	groupadd -f multimedia
	usermod -a -G multimedia $user_name
}

#=================================================

# Create a dedicated fail2ban config (jail and filter conf files)
#
# usage: ynh_add_fail2ban_config log_file filter [max_retry [ports]]
# | arg: log_file - Log file to be checked by fail2ban
# | arg: failregex - Failregex to be looked for by fail2ban
# | arg: max_retry - Maximum number of retries allowed before banning IP address - default: 3
# | arg: ports - Ports blocked for a banned IP address - default: http,https
ynh_add_fail2ban_config () {
	# Process parameters
	logpath=$1
	failregex=$2
	max_retry=${3:-3}
	ports=${4:-http,https}

	test -n "$logpath" || ynh_die "ynh_add_fail2ban_config expects a logfile path as first argument and received nothing."
	test -n "$failregex" || ynh_die "ynh_add_fail2ban_config expects a failure regex as second argument and received nothing."

	finalfail2banjailconf="/etc/fail2ban/jail.d/$app.conf"
	finalfail2banfilterconf="/etc/fail2ban/filter.d/$app.conf"
	ynh_backup_if_checksum_is_different "$finalfail2banjailconf" 1
	ynh_backup_if_checksum_is_different "$finalfail2banfilterconf" 1

	sudo tee $finalfail2banjailconf <<EOF
[$app]
enabled = true
port = $ports
filter = $app
logpath = $logpath
maxretry = $max_retry" 
EOF

	sudo tee $finalfail2banfilterconf <<EOF
[INCLUDES]
before = common.conf
[Definition]
failregex = $failregex
ignoreregrex =" 
EOF

	ynh_store_file_checksum "$finalfail2banjailconf"
	ynh_store_file_checksum "$finalfail2banfilterconf"

	sudo systemctl restart fail2ban
}

# Remove the dedicated fail2ban config (jail and filter conf files)
#
# usage: ynh_remove_fail2ban_config
ynh_remove_fail2ban_config () {
	ynh_secure_remove "/etc/fail2ban/jail.d/$app.conf"
	ynh_secure_remove "/etc/fail2ban/filter.d/$app.conf"
	sudo systemctl restart fail2ban
}

#=================================================
#============= FUTURE YUNOHOST HELPER ============
#=================================================

# Delete a file checksum from the app settings
#
# $app should be defined when calling this helper
#
# usage: ynh_remove_file_checksum file
# | arg: file - The file for which the checksum will be deleted
ynh_delete_file_checksum () {
	local checksum_setting_name=checksum_${1//[\/ ]/_}	# Replace all '/' and ' ' by '_'
	ynh_app_setting_delete $app $checksum_setting_name
}
