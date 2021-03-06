#!/bin/bash
#
# Copyright (c) 2014, Dan Yocum (dyocum@redhat.com), Wei Gang (gang.wei@intel.com), et al.
# All rights reserved.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#
# This script will create the Launch Control Policy (lcp)
# for a Measured Launch Environment (mle) and write the policy to the NVRAM on
# the Trusted Platform Module (tpm).
#
# For complete details, and a cure for insomnia, read the complete documents
# policy_v2.txt and lcptools2.txt found in /usr/share/doc/tboot-1.7.0/.

set -e

if [ $UID -ne 0 ]; then
    echo "This can only be executed as root.  Aborting."
    exit 1
fi

if [ $# -ne 2 ]; then
    echo "Usage: $0 <20_character_passwrd>"
    exit 1
fi

# TPM password - MUST BE 20 CHARACTERS!
#PASSWORD="20 character passwrd"
PASSWORD="$1"

if [ `echo -n $PASSWORD | wc -c` -ne 20 ]; then
    echo "Password is not 20 characters long.  Please try again."
    exit 1
fi

# Grab tboot kernel params from the grub files
if [[ -f /etc/default/grub-tboot ]]; then
    source /etc/default/grub-tboot
else
    GRUB_CMDLINE_TBOOT="logging=serial,memory,vga min_ram=0x2000000"
fi

# Clean up the files after we're done?
CLEAN_UP=false

if [[ ! -d /root/txt ]]; then
    mkdir /root/txt
fi
cd /root/txt/

# clean nvram
tpmnv_relindex -p "$PASSWORD" -i owner      || true

# Clean up the files before we start!  vl.pol is simply appended to, not
# written over - might as well clean up everything else, too.
rm -f mle_hash mle.elt pcrs pconf.elt list_unsig.lst list_sig.lst list.pol list.data

if [ ! -e /boot/tboot.gz ]; then
    echo "/boot/tboot.gz does not exist - did you install tboot?"
    echo "(yum -y install tboot)"
    exit 1
fi

echo "Create hash for tboot.gz and store it in the mle_hash file"
lcp_mlehash -c "${GRUB_CMDLINE_TBOOT}" /boot/tboot.gz > mle_hash

echo "Create the policy element for tboot (“mle”), take the input hash from mle_hash, and output to mle_elt"
lcp_crtpolelt --create --type mle --ctrl 0x00 --minver 17 --out mle.elt mle_hash

echo "Create the policy element for the platform configuration (“pconf”)."
cat `find /sys/devices type f -name pcrs` | grep -e PCR-0[01] > pcrs
lcp_crtpolelt --create --type pconf --out pconf.elt pcrs

echo "Create the unsigned policy list file list_unsig.lst, using mle_elt and pconf_elt"
lcp_crtpollist --create --out list_unsig.lst mle.elt pconf.elt

echo "Create an RSA key pair, and use it to sign the policy list, list_sig.lst, in both the input and the output files"
if [[ ! -f privkey.pem ]]; then
  openssl genrsa -out privkey.pem 2048 &> /dev/null
  openssl rsa -pubout -in privkey.pem -out pubkey.pem &> /dev/null
fi
cp list_unsig.lst list_sig.lst
lcp_crtpollist --sign --pub pubkey.pem --priv privkey.pem --out list_sig.lst

echo "Create the final LCP policy blobs from list_sig.lst, and generate the list_pol and list_data files"
lcp_crtpol2 --create --type list --pol list.pol --data list.data list_sig.lst

echo "i. Create the TPM NV index for the owner-created LCP policy"
tpmnv_defindex -i owner -p "$PASSWORD"

echo "k. Write the LCP policy (from list.pol) into the owners NV index"
lcp_writepol -i owner -f list.pol -p "$PASSWORD"

echo "m. Copy list data to /boot/ for use by GRUB"
cp list.data /boot/

echo ""
echo "--------------------------------------------------------------------------------"
echo ""
echo "Created policy based on these parameters:"
echo "    owner password:  supplied"
echo "    tboot cmdline:   ${GRUB_CMDLINE_TBOOT}"

if [ $CLEAN_UP = "true" ]; then
    rm -f mle_hash mle.elt pcrs pconf.elt list_unsig.lst list_sig.lst list.pol list.data 
fi
