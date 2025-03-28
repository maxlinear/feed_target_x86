#!/bin/bash

# SIGNTOOL = Signtool location
# PRIVKEY = Customer private keys
# WRAPKEY = Customer wrap key
# ENCKEY = Customer AES encryption key
# CERT = Cert generated by the public key
# LOADADDR = DDR location of the file before being executed
# OUTFILE = Output file name
# For example:
# ./sign-img.sh /tmp/kernel.bin /local/aliastha/uboot/secboot_chiptest/securelib_3.9/utils/signtool /local/aliastha/uboot/secboot_chiptest/securelib_3.9/utils/keys/ecdsa-384/ecdsa_keypair_384_C.der /local/aliastha/uboot/secboot_chiptest/securelib_3.9/utils/keys/aes-256/CRkey.bin /local/aliastha/uboot/secboot_chiptest/securelib_3.9/utils/keys/aes-256/ENCkey.bin /local/aliastha/uboot/secboot_chiptest/securelib_3.9/utils/keys/ecdsa-384/cert-12.bin 0x8200000 x86_uImage-initramfs.signed
#

FILENAME=$1
FILESIZE=$(stat -c%s "$FILENAME")
CHUNKSIZE=16777216
PADSIZE=17825792

SIGNTOOL=$2
PRIVKEY=$3
WRAPKEY=$4
ENCKEY=$5
CERT=$6
ROLLBACK=$7
LOADADDR=$8
OUTFILE=$9

echo $FILESIZE
echo "rollback $ROLLBACK"

# pad the image to 1MB more than the img size
function pad {
	file_size=$1
	file=$2	
	pad_size=$((PADSIZE-$file_size))

	#echo "filesize=$file_size file=$file"
	#echo "align bytes = $pad_size"

	dd if=/dev/zero of=file.pad bs=1 count=$pad_size
	cat file.pad >> $file
}

# returns if it is the last img
function last_img {
	total=$2
	cnt=$1
	val=$((total-cnt))
	#echo "value=$val"

	if [ $val -eq 1 ]; then
		return 1
	else
		return 0
	fi
}

if [ $FILESIZE -gt $CHUNKSIZE ]
count=$(($((FILESIZE / CHUNKSIZE)) + 1))
echo $count
then
	COUNTER=0
	while [ $COUNTER -lt $count ]; do
		echo Counter = $COUNTER
		skip=$((CHUNKSIZE * COUNTER))
		filename=$OUTFILE.part.$((COUNTER + 1))
		echo $filename
		if [ $((COUNTER + 1)) -eq $count ]
		then
			dd if=$FILENAME of=$filename bs=1 skip=$skip
		else
			dd if=$FILENAME of=$filename bs=1 skip=$skip count=$CHUNKSIZE
		fi
		printf -v loadaddress '%#X' "$((LOADADDR + $((CHUNKSIZE * COUNTER))))"
		echo loadaddress=$loadaddress
		$SIGNTOOL sign -type BLw -prikey $PRIVKEY -wrapkey $WRAPKEY -encattr -kdk -sm -secure -pubkeytype otp -algo aes256 -attribute rollback=$ROLLBACK -attribute 0x80000000=$loadaddress -attribute 0x80000002=$loadaddress -attribute 0x80000006=0x0  -cert $CERT -infile $filename -outfile $OUTFILE.part.$((COUNTER + 1)).signed
		COUNTER=$((COUNTER + 1))
	done
	# pad first img
	pad $(stat -c%s "$OUTFILE.part.1.signed") $OUTFILE.part.1.signed
	cp $OUTFILE.part.1.signed $OUTFILE
	COUNTER=1
	echo $count
	while [ $COUNTER -lt $count ]; do
		echo "cat $OUTFILE.part.$((COUNTER + 1)).signed >> $OUTFILE"
		# only pad if img is not last img (to prevent final img size to be large)
		if last_img $COUNTER $count; then
			pad $(stat -c%s "$OUTFILE.part.$((COUNTER + 1)).signed") $OUTFILE.part.$((COUNTER + 1)).signed
		fi
		cat $OUTFILE.part.$((COUNTER + 1)).signed >> $OUTFILE
		COUNTER=$((COUNTER + 1))
	done
	
else
	$SIGNTOOL sign -type BLw -prikey $PRIVKEY -wrapkey $WRAPKEY -encattr -kdk -sm -secure -pubkeytype otp -algo aes256 -attribute rollback=$ROLLBACK -attribute 0x80000000=$LOADADDR -attribute 0x80000002=$LOADADDR -attribute 0x80000006=0x0  -cert $CERT -infile $filename -outfile $OUTFILE.signed
	cp $OUTFILE.signed $OUTFILE
fi
