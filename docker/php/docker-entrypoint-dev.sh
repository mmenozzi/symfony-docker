#!/bin/sh
set -e

function exec_as_www_data() {
	su-exec www-data:www-data "$@"
}

if [ ! -z "${HOST_UID}" ] && [ ! -z ${HOST_GID} ]; then
	echo "Re-creating www-data user to set provided host UID/GID (${HOST_UID}:${HOST_GID})"
	deluser www-data && addgroup -g $HOST_GID www-data && adduser -u $HOST_UID -G www-data -D www-data
	# If the var dir does not exists on the host there will be the volume created in the Docker image, owned by root.
	# So we change its ownership to www-data in order to avoid permission issues.
	chown -R www-data:www-data var
fi

# first arg is `-f` or `--some-option`
if [ "${1#-}" != "$1" ]; then
	set -- php-fpm "$@"
fi

if [ "$1" = 'php-fpm' ]; then
	exec_as_www_data mkdir -p var/cache var/log

	# The first time volumes are mounted, the project needs to be recreated
	if [ ! -f composer.json ]; then
		exec_as_www_data composer create-project "symfony/skeleton $SYMFONY_VERSION" tmp --stability=$STABILITY --prefer-dist --no-progress --no-interaction
		exec_as_www_data jq '.extra.symfony.docker=true' tmp/composer.json | exec_as_www_data tee tmp/composer.tmp.json
		exec_as_www_data rm tmp/composer.json
		exec_as_www_data mv tmp/composer.tmp.json tmp/composer.json

		exec_as_www_data cp -Rp tmp/. .
		exec_as_www_data rm -Rf tmp/
	elif [ "$APP_ENV" != 'prod' ]; then
		exec_as_www_data rm -f .env.local.php
		exec_as_www_data composer install --prefer-dist --no-progress --no-interaction
	fi

	if grep -q ^DATABASE_URL= .env; then
		echo "Waiting for db to be ready..."
		ATTEMPTS_LEFT_TO_REACH_DATABASE=60
		until [ $ATTEMPTS_LEFT_TO_REACH_DATABASE -eq 0 ] || DATABASE_ERROR=$(exec_as_www_data bin/console dbal:run-sql "SELECT 1" 2>&1); do
			if [ $? -eq 255 ]; then
				# If the Doctrine command exits with 255, an unrecoverable error occurred
				ATTEMPTS_LEFT_TO_REACH_DATABASE=0
				break
			fi
			sleep 1
			ATTEMPTS_LEFT_TO_REACH_DATABASE=$((ATTEMPTS_LEFT_TO_REACH_DATABASE - 1))
			echo "Still waiting for db to be ready... Or maybe the db is not reachable. $ATTEMPTS_LEFT_TO_REACH_DATABASE attempts left"
		done

		if [ $ATTEMPTS_LEFT_TO_REACH_DATABASE -eq 0 ]; then
			echo "The database is not up or not reachable:"
			echo "$DATABASE_ERROR"
			exit 1
		else
			echo "The db is now ready and reachable"
		fi

		if ls -A migrations/*.php >/dev/null 2>&1; then
			exec_as_www_data bin/console doctrine:migrations:migrate --no-interaction
		fi
	fi

	# php-fpm is run by www-data by default
    exec "$@"
fi

exec_as_www_data "$@"

