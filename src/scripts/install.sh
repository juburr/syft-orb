#!/bin/bash

set -e

# Ensure CircleCI environment variables can be passed in as orb parameters
INSTALL_PATH=$(circleci env subst "${PARAM_INSTALL_PATH}")
VERIFY_CHECKSUMS="${PARAM_VERIFY_CHECKSUMS}"
VERSION=$(circleci env subst "${PARAM_VERSION}")

# Print command arguments for debugging purposes.
echo "Running Syft installer..."
echo "  INSTALL_PATH: ${INSTALL_PATH}"
echo "  VERIFY_CHECKSUMS: ${VERIFY_CHECKSUMS}"
echo "  VERSION: ${VERSION}"

# Lookup table of sha512 checksums for different versions of syft
declare -A sha512sums
sha512sums=(
    ["1.11.0"]="30872c3c9004e6699bf2afe587acc30aa6df613b4c01c66720cc5b8fec387121f8aab858191916b1182deea4fa1fdb0262af6937605e3eae1beb652aaa625231"
    ["1.10.0"]="ce4348e853bdaabe82e698f18137d4a7d58291f458c152bc8b32b5dd2895dd58b274bd1603b4b6b08069ef96733f08482581e9cf176af4aabd1bcc6e39b2e9f9"
    ["1.9.0"]="703e0d4afb0713fe84750b1cb6a60b61c24e728413077fa29ed474e1207a46c32ef4a968d4533b4a59045f8ee150e200354b2bbef42912e767fb40968b353f0a"
    ["1.8.0"]="0897cad6077c2abe9c095b20dfda240836b136892a816f4a550a374820e801f919badfc2d370ef54f80db57d8abc86388004f2561f90beb87e6c7b2889388501"
    ["1.7.0"]="3261a585d723eb427db271c997797fa376ce728ca4e708b1f418efe9c77687a0d93dabe1dd77d5578d09bd494e5d0b3fb6b3d16732f19ef6350748f34a07d58f"
    ["1.6.0"]="e174be826f7979bebd32776ed0ac4a6bd81d9524d8201e08ce799d8540b5b1bbd345f121abe454a3e1d560b1fec6d50603dfe1d91a7229a07530f487960debd5"
    ["1.5.0"]="3a66c91e2cae1ec89bae3397e7851369d06600bf29e33d968556a160faf22ad8a5646b447f8d537aaca6396abbfe9f59958080a825cff5a188c5adc6d19a9cac"
    ["1.4.1"]="4d9d4b68b20d77b021159478fb0f1a3ddc116444a26fea98c99a05132da88fb283099fa0eeba66c12a741fdcc81e274f40d15be8dad0007076ebce72f4558ace"
    ["1.4.0"]="9352c50939d0211ee9d1eb292bf1678906442c9015c6ad6fe983d691aefb0aa952fa86db897d5fc8747658a8ac82abebf3f88a844e8b60be636421b9595b0b0f"
    ["1.3.0"]="9e1e810e4cfc6b50ed6c6c0412c6798b43e9eda90a96ec372e40daf8e20835316b8cf2a534778e19925b8ac573229123e9f885386c816f40e84b069985c38bb0"
    ["1.2.0"]="60dbd15bffc4f4a098262c22c431c32e142e966d9f6fbf9f417979b6794df1729312b34406fae675b2a6b56bbe097b7395e877dcb29a5d0ba12b286e988fbe0a"
    ["1.1.1"]="add4f37bed3b4739aa01dbbd83a015bc4255aae50460360f37153069f3f921d7d3cbae85bdd7cdbdd748594acf851bcff634df6e259d1a6a90adc8e099c05f6b"
    ["1.1.0"]="ad12c45d43c47e51fcef5602bc18f525d852b67798a223c00c2927a499cde1c90420cb30d5591cb838050c2729093e1bc4b4e54c7b360e17b3f856c0977a6f5c"
    ["1.0.1"]="c9d82a7abb00941a79dd3cb712effa137e0c1cb685778240eecaa023fd0274ae781fa666a8e42ed162f5e5941f3f05c1106dd8def3c1dcff9162fe588abab3ca"
    ["1.0.0"]="7948a12c9b431253ff8cb3d0a17e66423b3e2882cbb461bd72aec4019281e898b2244684fab388dc1dc99712493d16d349410f5b46c020004f937d4a6f9eadac"
    ["0.105.1"]="044461756d67aa863c1a6d709e3f29865121dcf0c773a8b4c609155dab97baae9e8541060ee82d3b79fa532f5f3332827b5c6548f0063554d9525361b2650e2e"
    ["0.105.0"]="1f9b31dd6900395d07c2716c8fc2851866d6d38c60f209a0c4108551c981d1878eb125c1b31442f01b586db18755e172c6ca68d05eb5b3dd8c232dfe1844a654"
    ["0.104.0"]="aa216881a462a5d944f4c63e1ab1d3ff7eaf910d26a3f55d725a66a192944269fe9441943b993fa12b6897889671f8ff82c75e9f51353f020200690e8332f547"
    ["0.103.1"]="413b6705d04c539f114bddb5dd03e4d9cdca53175c01d291058410e6150a357e672e9d466fde4f211c189de1202e5adec11bb9f5cd93bd6ee3abec60a872db60"
    # Version 0.103.0 was not released correctly.
    ["0.102.0"]="9d414045319c739746320effc649d1fd75df0aca91fce4d40487ce3daef0d9a6d910150c3f1e92c30a5865004d12cd868625a3da34fc9b2cd740c0d2840fc6e4"
    ["0.101.1"]="30adac71fbc3e74a784d3a38f62a704bac1c6f7ade2d70e2d73f684a7ee339ca79ef3199c332c82f2eb773cb0cfb460f401af0feacf61803e20cd82d75717669"
    ["0.101.0"]="02af46edb87b165501abaeeaefa7f03319bbeffaf41893e2bb217a53feb83f9a4aafa98866f7b5972a221fd5b06c8ac86812bc3577312a74dbc07ccc9772874e"
    ["0.100.0"]="fe8cc5bfc106fca1c0ea80434bf05379aba9afcc45d23c7f5d9e77888b3420e52cd37505da1ea2fad065d02f71f7873b25041719ae00c22aea563e3dcb43e1da"
    ["0.99.0"]="142f48c8be88f4fffe949563632194295abd2daf54ee0fcad40a62869d42037b15ea5ab49570f4c8cb53ee0c433cc52aa3629796d209a16fd933a34b28f09c13"
    ["0.98.0"]="97ac0edaaccfb19582d0c0600fd2fefb72cfb44428fde7a413738bcf210e0fee495765ca01d00c0b11a547e02afe125e39285628d97d5106af64935800912c43"
    ["0.97.1"]="d6dbe7a1c787c4dc68bee3824439c37cdba6daa62e6faf1193c5619ae37d27a8a47d6df3f23e60402dac5c7f363e4c4ffb835b979f5fa0f3afeb7072b59def16"
    ["0.97.0"]="52d22dc6b26c23da22bd70d221621a6e18587c81f0836ff190a264bdafde3e14879cbab93669a88d3c7693b43243d7f790b142da9955a7acb6301527c0fab3b8"
    ["0.96.0"]="f24144df15bfb8f864ba901b50ed3b9864dbd3927f7e53b4244bb3687d4ca9eb93b898dc51d13c976da40a210af2b4853790d4e07dd402958f0dede68e90b22d"
    ["0.95.0"]="3a4c334d1497cde3a30061e599a4893ae4e025a03c86e173731b56de353436171e632f9e6a5a52ef2aed5ea55931093d5d1f873a2630a09eacc60352ac6238c4"
    ["0.94.0"]="82e5b82b251ca7c1cffb4b2ae63aabdecb54d457c906618341e7e0c0aafedf02c892a623f659e6e3bf35ce64981505a68711ea54fec5ea21bbd784ebe357813c"
    ["0.93.0"]="687db3fb5c25cf615947665f4615d7c64eea209cd21d5ec94a44268b23e2979f3d6703601d8b6ebb0c3c82e70d2cd4597df7f017568c611e8a20f4a0d1ac9a8a"
    ["0.92.0"]="5865fbab5e760a9a1175ecb6151c29915b3dbab792d93fa16e85984be9014a55eea4b8bccda3fb67647eb2daba7121f05c6933abd12b276e7e2f60cd7e8a8175"
    ["0.91.0"]="94bb479b926889738d568c17d714da4b2fa0f764136b0e009ae01a7d32d646ea60a9009f9b10eacd5f0b93ffeb92a72e5e81d167c9d411a7fbc20910ab926851"
    ["0.90.0"]="1c35f07e49a1af56c65193bbdbf8b51724a238f1160441b76ba7320631750805b51e4eb24f8cbf84298a8b7801e19f55c9ac1a82cc99a6d16546e94fcbee99a8"
    ["0.89.0"]="35a7df22d79e7ee20ceb187ad18b879e18d73841525126642ba13dc832c82ccffef70a1822f1f26d92ffe014b3ba4fc7e0693a141c4b5e31342ea8a7339726f2"
    ["0.88.0"]="6278668e4662b7f309be5e513de31daf4abd1b7d43d7e268537eedce1ecdff7e0783ca6d3fc85c742b1d890ba0cd567c222edd78af8a221dea6b6af90fa9cd18"
    ["0.87.1"]="4e60c62d9a4161ca72ed49037d12e07a8c6f87df495bffd46ce2398fb780ff254c142f4054f73fa22c44e7c56bd1520ede83d0f760c287ae4aee5fef351afaba"
    ["0.87.0"]="4ab5b5ab2a16d70929033ea0ed9aa15d1502e4d63fdc1f9381814703264a640ae4736c709f15829a12caa881a1be76d684bdfd0246dcb5cf47c60111353bacfb"
    ["0.86.1"]="425b6c6b50d2386abac716ec811431fadc4d68988ce2b3f742d041d10fdf29bab7e585b9fa27c9cdb211b372e0b04eeee19cfbf1cbc40f71acc3c95c62bc1bdc"
    ["0.86.0"]="ea16ea12e06a9efc7da0277a02e1191c1aad99f39da227b4ce11d0b6f6baec201fed76d275131f0fc3a338b3159c5bf5aee4027f4e3f04f693a1bc027179c447"
    ["0.85.0"]="5ec16506a0966cf9d2c2feb299fce9968b887080d5b7ab82d858b5663272536967437bc5e29bd19cd52e0727252aaf257711a37aff38029f8d682651b3a6008c"
    ["0.84.1"]="852aeca53ee479d57bcc680ab359040e1cdbe387a287dad1c77533619417e64b333658499453d67a474457ec4f5017840ba541ea0423ab54c54662d8de764443"
    ["0.84.0"]="56f50e2d29ea7491d705f4502dce963453ca6576ef30d60c36ee5bf4f8eb9234bdaa39a58aeb4ce022c50b595ca58584ac9516194f7fe1ebb0f83e9d8347b5e7"
    ["0.83.1"]="dcf240395c26c43a27622495932c52fd748e5b56f5a20ae0c6168d3784a71fc4ee3d61a21f44ef0cc2a3b9dec74ae714cf5be583906541a8287d106e7f0d4850"
    ["0.83.0"]="1b35d29a0c9838e74ece0ab32ce4b74d2094319285d84ca36940a6a90519e34d57c9aaffe2cdd3785f4cecf28adec29f2b6eac49eb54a97f58e74d040826e94d"
    ["0.82.0"]="53a2b3d7cd262fbf19ff6ef86910064c6542ca57cd0c0a324a8212112ec5801295108966418503a57a76c05ca175394315cf731fa14f152ce3d031f0f041a044"
    ["0.81.0"]="872c70386841d4d5208349e50fbce15c1e858b3f3e0447293d3be168b2a0973671c40d56d830d92d60fa09e924491527f51c1bdca96f8028c2bce36f2b9a28a4"
    ["0.80.0"]="0ee23c06c13fcd6b5f56e0fb4f729c343d6f1327dcbcbf6ffc57b1336a01f908353f8fee2ad4ed64db6a0b6c118013c43e6a9dbf3d65e0d3785d43f67e0271f5"
    ["0.79.0"]="c60e725464ed3e7f51a84bfebf281c873a3e6c0765a7ea6d2503cf7bde12a81f1fb846131cc08a72f85a6bdc6028079d2226cfe1f259f56a01dcde261a8fdeaa"
    ["0.78.0"]="a8f79fed90dbf3ab278f4f513cb3f6db1ec8087de32bb066667a559abd59e5f5f82f22000a8ea9b15cadf1845eed2f8f8cf0cc61f11ab9807ce099b109985d97"
    ["0.77.0"]="b4304b2170ea7152a8665c461043d7c8ee0cb00f75b998a4aeab1b45c474f945ef4d459506faa0cd68780311fb6f04b83dfa1673e4c7c7f4af4de30bc451b5ad"
    ["0.76.1"]="290fa2c407ef41deabab42027363da73abfe97ce78348a722a70d685743ecc6cf7ffec97d6a345011da27fb6ddd4dbaf8e7ab844855b9b01d4dc781bc1bb616c"
    ["0.76.0"]="70969f9c1757cd1a50115ef5990d0f2d5ee80ef8ff190591ec60cce84ff8069ca516ac7f467148bc7e93d41e57b4a3550830483fb1fd7a099ea2e592fa7b3b87"
    ["0.75.0"]="338c18544ba7c2459b6ae8a009b5d662085d9a80604aed815db0013eb8abd3f7ff68996ff4639199818270c611f7cff4609cd025b8220f99373baed7b9d2db97"
    ["0.74.1"]="0f7db2cdd65d9c41eec9898c8b7b29ccdb4bb71af4f2309ba2a407ccad02fe9f5ae7e51faa33f7c22c6ab1522e3ded914b212738ababab7fb4e055e5c1f87eaa"
    ["0.74.0"]="e0fecb33c61ca021a1f97560c1403dc0a5808f09004901ebee6bc8735480be7c9603a5f539109b6571a3b5c4892246684c28e6f7bb35f74021d0177053c1ba6a"
    ["0.73.0"]="f088b588283a083b7fa186258a36ae0130fe053026a5304194e3b1896283aab0334b504fde7774224af6cafa2201d94e46e615eb04b5aa1d0286c2ab00dbf709"
    ["0.72.1"]="0d7c0024c1c3e84237f17c443a08ed90dc8a3d831ecd8d8f7a7f16510a4d9c253e7eb497c68d9fb42ac7c70c6fdbb0715c6f01a258558aae232133593f00fab2"
    ["0.72.0"]="f413ffef66ae4c8125f59a75d59ada080f033f00bff31bf09355f7f1c0edfb5355e55e2d5a22aa220772297743db9545dbe947ac9af16fdf2e62c09515d97425"
    ["0.71.0"]="8856116b617614ddce73fec5c9dfce9cc672a87e6b6d75a1ed724fbbc0dbcdfd7d10760e22193ed4e43f017cf2b895c3669080708468d1cac7db8da09b89a0aa"
    ["0.70.0"]="b4e8528723eb81046225329ac290ad5cc5df11764d8d24be9681c159a1bd313712d046882f58d0ca92239160e5c205b136aa2d0625669f8a18b4d13638fc1926"
    ["0.69.1"]="7ba5d041023c3d6640c547d83b3ab93b5911ddbb1f875d83d11c599480b1a5e6b8a6175ef5e8227965d4ac983163c71b8ecbbebc919c312978c4b8bd726517f3"
    ["0.69.0"]="6a5645ab106af0d21e35d10233d78467d985df26605669170bc14723f81214cdf6ce2357a3d16b885cb8b9fb87af9a767fe511bb073ab3128323188b5e51383e"
    ["0.68.1"]="5ed3a74c7bb108ffdd58247a980005ed55772965fe64c90451f3ec4422f2a043dcb9d2a0e558b135df20012edd8a33827ee680afc399a0909b02f9f5c39146ef"
    ["0.68.0"]="3e460e15d6db5e0ab790177784738f044dafa9ff4e311467097046635170fffa451f970b480193bdf33c3157faf28f20671798e9b50adb9274f64e62f2d68064"
    # Version 0.67.0 was not released correctly.
    ["0.66.2"]="d0cbc3c1b6f5cf6806b12d295ad2b488c0b37e559b9eea4ed68ab196b46a00bb2bc13d718ad1fcca3b6f5f330da11b5f284359a9718d5a3aeccc5a3fb6286a75"
    ["0.66.1"]="3045eb7bc6fbea3669f556347f156fbfffdc82d23cb816941884f7d2cb179bd0c8c1ecbdcc41ede70a53461361511361002571477b3740c8f12072c930738010"
    ["0.66.0"]="a69b531136a06c07a52827ede77899b8d9c7a5c79cd337968829063883ef0181fa062109ebe62c9d49fef65a52cc0fa289e469eb05320b47d9e36222bc14e006"
    # Additional checksums for older versions should be added here...
)

# Verfies that the SHA-512 checksum of a file matches what was in the lookup table
verify_checksum() {
    local file=$1
    local expected_checksum=$2

    actual_checksum=$(sha512sum "${file}" | awk '{ print $1 }')

    echo "Verifying checksum for ${file}..."
    echo "  Actual: ${actual_checksum}"
    echo "  Expected: ${expected_checksum}"

    if [[ "${actual_checksum}" != "${expected_checksum}" ]]; then
        echo "ERROR: Checksum verification failed!"
        exit 1
    fi

    echo "Checksum verification passed!"
}

# Check if the syft tar file was in the CircleCI cache.
# Cache restoration is handled in install.yml
if [[ -f syft.tar.gz ]]; then
    tar xvzf syft.tar.gz syft
fi

# If there was no cache hit, go ahead and re-download the binary.
# Tar it up to save on cache space used.
if [[ ! -f syft ]]; then
    wget "https://github.com/anchore/syft/releases/download/v${VERSION}/syft_${VERSION}_linux_amd64.tar.gz" -O syft.tar.gz
    tar xvzf syft.tar.gz syft
fi


# An syft binary should exist at this point, regardless of whether it was obtained
# through cache or re-downloaded. First verify its integrity.
if [[ "${VERIFY_CHECKSUMS}" != "false" ]]; then
    EXPECTED_CHECKSUM=${sha512sums[${VERSION}]}
    if [[ -n "${EXPECTED_CHECKSUM}" ]]; then
        # If the version is in the table, verify the checksum
        verify_checksum "syft" "${EXPECTED_CHECKSUM}"
    else
        # If the version is not in the table, this means that a new version of Syft
        # was released but this orb hasn't been updated yet to include its checksum in
        # the lookup table. Allow developers to configure if they want this to result in
        # a hard error, via "strict mode" (recommended), or to allow execution for versions
        # not directly specified in the above lookup table.
        if [[ "${VERIFY_CHECKSUMS}" == "known_versions" ]]; then
            echo "WARN: No checksum available for version ${VERSION}, but strict mode is not enabled."
            echo "WARN: Either upgrade this orb, submit a PR with the new checksum."
            echo "WARN: Skipping checksum verification..."
        else
            echo "ERROR: No checksum available for version ${VERSION} and strict mode is enabled."
            echo "ERROR: Either upgrade this orb, submit a PR with the new checksum, or set 'verify_checksums' to 'known_versions'."
            exit 1
        fi
    fi
else
    echo "WARN: Checksum validation is disabled. This is not recommended. Skipping..."
fi

# After verifying integrity, install it by moving it to an appropriate bin
# directory and marking it as executable. If your pipeline throws an error
# here, you may want to choose an INSTALL_PATH that doesn't require sudo access,
# so this orb can avoid any root actions.
mv syft "${INSTALL_PATH}/syft"
chmod +x "${INSTALL_PATH}/syft"