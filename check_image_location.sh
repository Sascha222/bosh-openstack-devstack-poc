#!/bin/bash

# Find MySQL command
if sudo test -f /etc/mysql/debian.cnf; then
  MYSQL_CMD="sudo mysql --defaults-file=/etc/mysql/debian.cnf"
elif sudo mysql -u root -e "SELECT 1" &>/dev/null 2>&1; then
  MYSQL_CMD="sudo mysql -u root"
else
  MYSQL_CMD="sudo mysql"
fi

echo "=========================================="
echo "  Check image_locations table"
echo "=========================================="
$MYSQL_CMD glance -e "SELECT image_id, value FROM image_locations WHERE image_id = 'abdbabda-0c5b-40bf-9382-a98d37cd21bc';"

