#!/bin/bash

set -e
set +o history

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
    ["1.14.1"]="ae05957acb0714361723065d5f107ffce81367da73abb8a708c19209e288d56c31294526ccd7822300a7fd1d324ca54e22897071f498bb7240ff648de73c8dce"
    ["1.14.0"]="12413850c3c906aa5169e795377e2cb3c7914271cf4ef671c4db742742414fcee02788514c87ca433906b135be9235f0eecfff3b056188c36ba7901bab7b1f7f"
    ["1.13.0"]="eb0af40485b85e0fdd1cd52ee67ff193cdea93a1cc3790510d7378e6b20123eebe7ea54873b2a66bd141433dd12c32fffc95e0761844c58acfd20d190feef721"
    ["1.12.2"]="cd521558641bcf24af1e130ff4e1cd45302e78bf22b2fcf0d04ff831fe27a926f3129b3a3b02ac6fe4497db9e8d43d40a23caf5f847127fc0c39e714724a137c"
    # Version 1.12.0 and 1.12.1 were not released correctly.
    ["1.11.1"]="9c55bbcf5b248b52dd2b9d0e0785abe548d0550db2202c1a66b219b2653060ee9aebedf8e3e94bdd6150897a5a47154c46637f375ee852105d665b7b9b43e437"
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
    ["0.65.0"]="60e471ef08346abb1121290438db9ed03692a9772fd2f7d25e2fd2a23d1f3022139c88525702f1a8541058e7e8ee75530a63460433fc2a4afe956fd558c4417a"
    ["0.64.0"]="39ba231cbc82bc913f62e5cd8a6871b960cfa384dbda59b1ba2b9ff4068c9aa1739f083c902de6f675c151bdb6095e3fb0d455928439c4e7bfd2f5489d158101"
    ["0.63.0"]="ebb07c5c217014dc6e3d1b6589740173facf6d020dd5e38b8912b3580572a89f694546fb864af3893e36035baeac285df13ca1e802a593a1f8dc8354ab8e1264"
    ["0.62.3"]="90a41eb35632cfba4abacbed419fc815f5a5afd26efa21d67eae3413e9f003a8a459c9a90368cce64284cc527107df654e8ec9f4747f92eaf570c736aa7fea66"
    ["0.62.2"]="7af5d1810507af46bc8f04b6ddfc1a4b708cc2c9f52950ac12f6ce8b1dda893bda632aa63b4276cd92c2e13cbe9b4b2e1eb9f07672d90a282f4c4f9761b067db"
    ["0.62.1"]="8b069c830f78dd918edc4a574beea773e4a61326cf86ce70f0a835003c9f39fd5c925866393c3074c1628aa3f0b6b50f1895bbee7fb4ea9a376434c94ebae41a"
    ["0.62.0"]="d7534067373318db2833f5bebb89eac7a8b63c28b92772c133d5446351b0c462dd1c10547794597d70d93a6221a3cbdc43eb96af388959c49d7bdefea8049ca2"
    ["0.61.0"]="b324d73e6aa9bdac3d4bfb335f025c88c6fba1dce723a358aef3154ad248036d3dcd1da9f7f4ca991397e2829a1aca5212503fff923728dcddae73a69f173a55"
    ["0.60.3"]="460af0041046d1944128324c12068e19816f9e48edda3e28e927df20217b5eabebf06ac551464612be31104f599dc1012f63cbdbfb3766461a98c22c004a9909"
    ["0.60.2"]="2d3b3b12a74a97b2be96edf2baa6ca16af6ca39fdd92e7f0313e2277cf99168075809ea19ef1cb2dd393cbb9753d9c8317520e487d2336c05ad1f7935bc9c69e"
    ["0.60.1"]="517766e1cedea55fa7e1ed780d0cb81d3f272eb4433368be5d09f521f5cdb91e14645d8110bf2b1097ce3f6c347feb6cc55b2ce397ae7a194e7582218bfdb9be"
    # Version 0.60.0 was not released correctly.
    ["0.59.0"]="723fd0536bd06ea73f29bb1f7f7bfc029ce1b7be95ecb2ab008ce74328ef1874dd796c5ca3f924a25365970ccd932077c1eb2c3f092a69d1b2586ca76f4f1ac7"
    ["0.58.0"]="640ac17acca75e8c5505b3287806737cf669c9b694eb2874e97016472942f18d7a50cc4f9c2553fbf9b3b73de574c2769297dd1321988445d4d57442fb8f1a51"
    ["0.57.0"]="12718b777402bbbcd916c4e959b6243f1a12f8b15b72e2a78442f8b274588ec8886fd4d4d62c9e57b357ba8c011380720120d09ee96ee8c4332edd5f76df793f"
    ["0.56.0"]="f6f05206e1ebdb7c71a7c51ff6047c6f8235e6dded9a99a4633c579cd3a6f86def5871a2e742928197d93400e43ca18b20a0ccf1a75d21d1df70df97e1c8ba7f"
    ["0.55.0"]="22fab10492a7d3ac83ef904e8b2fb6b082405959dacbc1532ee5084e330f494c0aaf770a177e3fad015ee076240b216627690b2d6d2cf0d4f5e4fb5cab76e36e"
    ["0.54.0"]="ac463d3bfc0cf38dd464bab38b50eadf3ce7cbce79cc96f7b658599ace731d3ee64200f2acf3c23bee2f97066b88dce8fbf00033b120b3c0f596c3517ba8d4e2"
    ["0.53.4"]="f5023720e9ec5d1d63bbca798a83fd99428479e2c29f8d04662c29e5783d3fd800b4f76f4f235e2a7671ce41284b51e85eaa466c00acee4da4a6737189f884d4"
    ["0.53.3"]="d79e93ba8f7a5d4b7eb459460a44776f0fd5b93cb9daf3e5fd3189b3a9d6632aeb440c60d11949e3f1573e6d0c2af0982b79d2ddf780e18119b565b417558d2e"
    ["0.53.2"]="c484aabb6c90c026094ef26b660af9dee0a414f6a51cda9ea225dae01a2155fae5d25fb6b3d80ae8663577d0088d7627ec503940577196ad85f483560208cd65"
    ["0.53.1"]="84ef445eb00d996790db0581d9ef9b04473a72f968ab47186e30ca8b5c226bd7b84133060940a775cbdde601e58950f44b1d2d2888de021e535a826d12adc92b"
    ["0.53.0"]="d8039e0d16b654bcfa944838402cab5c45e3e48245054b8423d83b21bcce312223aa029be0de4fa50cbcb8856d15c006618472b1c9ca7f57471ac5dc89f98149"
    ["0.52.0"]="1711c09dd4ed36fa45cc0d53246ab3a0efc50d3e0235480eec87a1131e2b6809de6a30811654bca06957806c01e707909d1823bbb6efee8ec26c633d78e3917e"
    ["0.51.0"]="0cb397521f447b7712d265ed06e32fbf1afdcdeeadb864e81ce991fd71f8cb90c4428456c4e38d95e72b2a61cfe24f76d04dbb5090fe184f1adf062b79c9726e"
    ["0.50.0"]="cbb6da5019a5dfe71dfd0b1f6d70b70c53b22aa89d0ff51f6ec236693d782bed9a3a41e31ea5131e24914f9279793496654246ed409343f3a0a76af3d3771c05"
    ["0.49.0"]="3e2c29320a028494b6097c9650666d1661e7ed92db26ba1aa9918f157e42280f0a68d91c58e1632f0bb2f814ab12dc24ec86a2c2688e6a50bbf8706c540f82e0"
    ["0.48.1"]="3f6fff5ac80469d6077123cf013e15557da053243a805f22e8e7df8b131ff9e433527ac9becf0d00a9b644d121c3b9f0821ac480956fdfa521ba0718cca2fb10"
    ["0.48.0"]="4312ff98fe71dea6a303f872f6ad050630ae327ba11641000d59c210180dc0b3c3d8438465f938cdc44450d4aafd8214d30cec179f2502304a8a5f0622180527"
    ["0.47.0"]="7210e150725dc73c95bff4f9b2c6cc192682cb7b96f28c31dfb8f660103e5f77c786d0a0d4c3fd1e8dcda7b19ad040fd996367d258b83ceabec3f36b276ee049"
    ["0.46.3"]="f70b3c157eaf0e826b5a7db31f74334d17470af7b012baf3385501fd463b1d48ee150617d565c9cc1118fb35c3f580f8d7f74acb5deaf5dd699ad14cddb74dd4"
    ["0.46.2"]="fb51fc67ecc6b4586c86165bfbb3b8835da71da7bbf00b0201a2bd540ee15b718cf90b1bd49749c8be2b7ffc366d99c0c5338784c06974e1e71cf3d8d6f1499a"
    ["0.46.1"]="08f5f611ad73dbe003a2c49243907d3d9f9ec496fece8944b7c508307e3495ac645a857e4a84225028379aace7555654181895554ac55d2b239e23f94155209e"
    ["0.46.0"]="b8bf8e0f53979c1e50cda75607739626098c6477b57d2587b70f947cd632ba4fad4959d425d2497d3b59504d9a6c307eb6523c24978d128899a3552adb47436c"
    ["0.45.1"]="2db2c3cefa73c0eb9ca5102ee9db21356d2e29553de9952f086f12d73e9a47e1addd4c067f1ffe2c7a851582e60cdcc44bc24509998ba768a508bd94471410fb"
    ["0.45.0"]="a647066af27039ae5d3fc4e2dd00a1cc93a86f14e633186810d07c612990e0bbabea631c9b98b08d69ab009f0cc5b10262ded1badac5efd80c907bb5793dd397"
    ["0.44.1"]="9d36bfb760773386d236ca5b93a5821d4f3b5af1edebf9d61de3e76dcfb5a8b34741cf688590cc1c3cb9c01b2d85676ffdcd1e11a086723ca21e2679fd3119c3"
    ["0.44.0"]="3902a38f9590338822d2d7b559a88fedc99f6def076cdb8da01ced4059f6c61855f7cfea25d837f386b309bd759961d27f3ddb67aa49d5f01a637d1d9c12e237"
    ["0.43.2"]="327081a6add245800e719236535bb127811946041123d4ebe281dbc043833b49bacb232e2544f8323dfdbe04c40634277c2f9f30ce38c043c847871c877af615"
    # Version 0.43.1 was not released correctly.
    ["0.43.0"]="0b153a570c10a7bfed3455d4414b8da3fd967a00ad6a4449a8f34a1b4a8341dc79b1e8a0e466cdba68c28a05545104f1979f6b784266ff2f0db87c4e945eb409"
    ["0.42.4"]="2d95048432162f0fd947447c2ddb5c7f70e7150c38b554bb8c1ccaaec5dd94192b3412649f5e0a3c55c7d9186047a6ceb5767a6e8c5ea0492eaba0dbb3773ada"
    ["0.42.3"]="b691da0034807cff41122ff935290447f8a097e4d7e26679debbf77569ccd2ffc99592acf3c4fe7109f4b1fe446d56b2bba4293bcd00587fb3e5bc3eb9846f4b"
    ["0.42.2"]="44a16340eecbbfff6b3f13bcabfb5c4d47842bf44f2e17477a10f93aebfc9863bd4837acaa06b2668f4360aa6d3c94a7be6dd9e2a311ee997f8eaf30d59c4fed"
    ["0.42.1"]="01cf1c8eb14744f7cd67cda938236043cad0216e0095edb8474f636d6afae8541114b7ad7f69cb050c8df12c07c81e00b20ca349e16537f9b810433fc939239e"
    ["0.42.0"]="322026255159df81ecdd99a1cf895393a1c534c07dc028d0a612dcc0ad088fb8fb0ff840972bdb2fb89800967e8dc5d290c38c6871942c78625a1b5ae8ca4029"
    ["0.41.6"]="eecf811c084003867c9bfb1f01463ff1ccf48d01b510bed8f80b5f0d1f5bf06e35332c6ed5e28bc352fda971b62b2f0cc044492371233ef5f7eaac959e01e5bb"
    ["0.41.5"]="5d499735778b777b4a464631e1f3b555fa2f39d76b9f9b6c0feef49b3609df5dc50a9779fae12fedc13b63bea1a0341b3c9c2a69e803a094f05b897e1137dca8"
    ["0.41.4"]="29f06325ce9bcf810d9d999ecb985fc07ece8d196ab440e0c8e8c5cd610bd90e8f1dc007e55f20062395f274e11b004e030088a8c2ac516a71eb30e538298ca4"
    # Versions 0.43.2 and 0.43.3 were not released correctly.
    ["0.41.1"]="fe578bc9a27fc16d6c5f9788cd82b8200ef905e2a70daa0ebdea9e466aba833ed24acba7690f94314f11e39bb51e20b5072f68302a0743e1c7ce08691e4f9483"
    ["0.41.0"]="a962f85a6b164c4f91ba7acec2bd27b9d306a93d7621cb95ab5d222b5be588bdbf80503808208e3533196d00a6d4d83b0b75d5f4dcd323dec51e10ba406d00cf"
    ["0.40.1"]="6a638da02e5e3a349b48a373b22a392077b1cd5a2aa562af4b0b0816dbeb25df2a6702031b496494669bd90a15da8d59e2dea61aaf52fcdd899dc3b5efe6619c"
    ["0.40.0"]="b671e0c08de917795e8e939f5242d5a155fc01a13a0ea976a7a0242f222fbe5cee41a1a0cdf06d497974f7816ee6b4247bae6b45db03c46927074955717bc8ac"
    ["0.39.3"]="d1b90bd25fab4a2500bb37e81e44abd8e55d7cad21d926faa9b5c633a89c16b619a9fb293f23814addc8864c765767db5b2095dc64971083338277afb42f432c"
    # Versions 0.38.1 and 0.38.2 were not released correctly.
    ["0.38.0"]="895d788eb53850913df49bd4da18497a6fcf279a87626e4ad5447823d0bf4c8c255b929319b9b217fd91230e67e4f9ff0a5da682c3854cde011336b98e670bc9"
    ["0.37.10"]="5e5fa74c2fd0a5f4fb078674c1d9dadca6d0cda4f17129fffc6ecf8e42614fe69ce7f1a46c1b0c63bee337f3c944e250b6bee191604504e891a1c308d8f9e35d"
    # Versions 0.37.0 through 0.37.9 were not released correctly.
    ["0.36.0"]="7ccc4df6fe04f1c5f57acbc054c358911e7e4fc55a1b72bb057a982206f492a5dbb32201e3314b5c90b0466e9c2da3509b342b799f91174e0ad9bf95d446fddb"
    ["0.35.1"]="8e55ee6d953346b507e0a60966c8008b7c8fcb329ac8fceecb965f55d7b0e05622ad4bba2a2aaaaac7c2e4a004b94749c1c9ab136182a6038ff601150a723e6e"
    ["0.35.0"]="d15abd920615d8534e426ecc29908a7d8c637a40e87d74c83bd72f279d0f2754336e81ada970b06177bca9be7661513f09b542f1fa487e24ff4aa29c621eb899"
    ["0.34.0"]="d4815a8ff3cc6718fc3f8e21fc25399471787a505c78c1e8711f16cb8d8defdc4437564561d6b1f707a5d1c86ee0d5358d22b880bc11ef528da38f1a495d06b1"
    ["0.33.0"]="0bb84332b78068be74506d478bdf654e6f21a307a675170fc24dfb380aeca7ddda54de4d6a6ec17beede0f01c4e9bfceab83a2b42b4d8f1c73a58c7292635756"
    ["0.32.2"]="6913d0c0342f0de8025b876471d9c63942392f24fedc93c1d4f3f87c5049cf79545353dcabd151de634a83801bebce6cc21fb31100c675ac9a5ac27a482c2e79"
    ["0.32.1"]="ac4ac41c330e40675e3b8f72cac7f854147184214304e017a9a4891328d38a444b6d39aac9a0a16f570a7abb25c674770b475ea2a6341202ec3c528fe0a3a022"
    ["0.32.0"]="697f208b6a6b552218d7d171f6d94d63cb80eff95262d2c037d900f0234e21401a426fef599dbb1d99ca291353f95ac1775e8d3d934463cd1c12067ffbdd9b73"
    ["0.31.0"]="9f972f350ced01298ed5b0f83bbb0f010a75d8bcc5ed5b90dd859fe34c024697c00b81c63f409f7f5a1277555f715a2526e25a72738b352beebccb589d4285c3"
    ["0.30.1"]="de7f1a885955e310e73a5c15066b793434f46787b0a0dd7eae91d7fec4d2ea19ebe2abd008d1c5708648a1d4d78153ddf8639b3bea8965503372482c01e983cc"
    # Version 0.30.0 was not released correctly.
    ["0.29.0"]="7d50f36b6ecbd870b73c48ff8cbfc6b2f96e577fa1b06ce3d7dc145b2fbda5e87313fb34c0e5c7596c20e4c1144f7064d730175e0c87b3e8d85faa0d2ca5b983"
    ["0.28.0"]="13132394dfff163a32d8159313ef8b9281be0cd00980f89525ab62ec661e716a215397a5800e0c07abc8d3d67b1570312b9ca19d49997c4da4801263e4e1f2d2"
    ["0.27.0"]="152062f5d3c9dbeffe78c89a0cc95a41b6aee270b871e0ec88f9b85f30cbfad53168cf5b7cab722b37a716c19880c9f670c537078d03cc3d231ad8ff0c79ed41"
    ["0.26.0"]="a21be2972af09fcfc10a7fda4415f0d2513f3c2f88a3b5565f50926a40621339566034c201e6eaaf6fbd952300b0de01a6b88f85bfd2160a4965851377d773e7"
    ["0.25.0"]="2ff0a3fe32dffd7a049f346e00572b1312083e79199d8eaf96a0a75cc27d9cb53e68def30dc149298f5133a51cd0530274e1f56bbd796e1100f65c34d89be432"
    ["0.24.1"]="af79d27c358281a885e36c669b510a800d07d8ef5570adb9d873071a50eb99c1b2d6514280db1b922277e4d8d0c2204ca88069e811eb20bd52ed26b4d3d55700"
    ["0.24.0"]="1cbbbb3e8f810ec8ddc21b78abfbe3773029b3a1a70676c859960d35e2419d500c278da0b8a16bbd03b3f2751dc1c65bd96f9364b9365f67629a3b62cd6f7eae"
    ["0.23.0"]="b69bfa7088cbc97db46cbd9c0cbe6ca6661ba34a7187cda8d0d29ef7f7efbebc93575c037a9d76fd3a5bc789db51a52c6ff749e95de9464df66789e540843c4f"
    # Version 0.22.0 was not released correctly.
    ["0.21.0"]="6f04e03c48f8e957f0a3a5dbcbb5c15d5617c5dde2a0f5942710d9c3c18366decc01e919376084d652d0c48288fa6383a9cd948724226d55c846d45838c19a19"
    ["0.20.0"]="6c5345c03833d6c9d0336b694fb10072b65f5c36d8498a690112b0445a69eac7869d6e215d739f2753c8295519ac8a2d66223752e65a7dba0a3dd6fbded6ba9d"
    ["0.19.1"]="e3fb0e1f38acc6973a56c6e4a1fe9403474d7a82db3df9e78bc5286eb483ad7c483bbcccdb47b8d731a92429758976e80e5ab20803374a730b674dac360e13fc"
    ["0.19.0"]="5460540c917e9f3b4449527f90fce52d54e51df11ee1088a54589ec3797490cf96a227858084500d5e76f6b432ced6fc8129af851c296b0bcd04c32acf84cdd3"
    ["0.18.0"]="d629012aeb2028de479fab8724e94d6e8d53fc549e1d76f956a873fad1f58b54b9f050cba9a62ad8a08964b96901e321d9959f2b8fb8e2f60e048a117daa9e97"
    ["0.17.1"]="00f996e20eb9033edbe8ffc19792753e05b5a0f16ef8e70c43c1a5cad1cb575bdd7c44788c936d9f5b3d34d4221d822d97672dc1af4e57bb1b0dec39b29b8d2d"
    ["0.17.0"]="50c2c3f7ad0a620d4801747595c3cac27de64a5057ec1fe4632a50633d11c31e244a7281e9a57f60e5c092487e1bd47e3660728071d7a07c017c96815b926fcf"
    ["0.16.1"]="4e1e17a41ef1fab3d66b4b6f2ee49fd140f530b2fa7860d82248985cc3be226a2aa28aa06d24e46f7528153544ea3f618db081eb5e3f07f95a40322f25d178ec"
    # Version 0.16.0 was not released correctly.
    ["0.15.2"]="f1c43ea254ce7950bef0deeaa6f59a57fb4e1dd3760f7c5a96596fb2f3cd7d5124ea16ff0bcb7e68673ba9f2654e8d9cef1b4753648d0091e73a0bdffcd0c62e"
    ["0.15.1"]="de19ce2669e5ae2939d602d5256543a7ab3aa223b0b7f8ec9c78260715015c1fcb499c9a5f8d5a3b1c1d66d8766e5777932deab7c2d50172a8370b2badfe10cd"
    # Version 0.15.0 was not released correctly.
    ["0.14.0"]="1cd2f920a43ae740176e1505c7a3cf15ccc68f0f0678ab9562603ac491640f021e25ea3bc987dc22ebff9e8a764efffec6858cd4a032e1bf69952f9622dbe1f3"
    ["0.13.1"]="b48b7280c2f089b129c47649631de1fe9278a10930c5ae13730d232937a2e297ca0fd3191a5e3f40eed94088fc8ed950e61bbf9b55bf24f1751563aeb9ff9a1b"
    ["0.13.0"]="90402a4907042281fee8b7a10f58c58846a7b03b4a5fe2e768f6a6ed434544fb4276def294fe40c3a1bfa0a5393837aa70cd4ac3b12f03be5207447ac055f103"
    ["0.12.7"]="e61aa979b671de4078b34dc52ff0bd42a8bf878a5d356c82dd5b1d3c8c72317dd149b9adef53bc972175d231865775fc5d0798f524e766dc7b5a0e6fa8a15f60"
    ["0.12.6"]="13f8f765d0b6d9f5f3ec3b62e140a63f55df62f2f25ee350f583f25ea6fdae3001806d1d4f20a321f69cc2b131dd8596e02bdc529d84c0c0141400823d52f890"
    ["0.12.5"]="25ee8f269825a2202645959f17bae88cd78301da74d140acd5156efd51ed2ec7faad9e4ae25e3060e24fde9ab231b617688ebd8b8f813e60f310748f4b2c7d88"
    ["0.12.4"]="08f816d552cff9925e766aba3ba9bd28f77b01ad340bffe41d75e42137e7ce32ca317f2e621c050fa649086ff053ad6da62a5c6d3294436f62de67120bcb0016"
    ["0.12.3"]="5c2b3e80072e2afef9cef80ffba8677c2b6146ade23033448c001ae0bc2f36b4c28775ba78403cea5154ea07855da70240fe4471995b5d038ca0076834186655"
    ["0.12.2"]="34e55b8248ac6d81562dfb652c1f40a4796705cadff9e5c022c7f025016457b3727a6d6a3b07c18e3a0ad5a1ffcd08a51aa7960ddee07c3c12d6059c356823ce"
    ["0.12.1"]="2e5e4554f31648404f6a63c866835763b4aa5e07cb301b85619100d99b4dd66a8c00564469a95ba225daa206190fe9b04e929bea93a0e4425837dd793548feeb"
    ["0.12.0"]="7f4238bcc6e3368156d0cc197cce98dfaafa903c712437c5b62b2be0a62648c310e44f54f54a5ceda0f4feb66b55254ee7f70e3f025541acd7a09ea752946159"
    ["0.11.1"]="4d5eb7f2de3d5d67178ba0680c17f411f1fc490ec3a33b7950c620168e84d605c9c56ea20e85ad59de4bd8b24897b41f4e5129922b484c206e92c12ae490c30a"
    ["0.11.0"]="b14c2f9a5a7927134b30bfed56f53327c223c789059a9f4363ec084d2d34972baec43eb5abe4f37ca7dc796a0841f30a21e5b3e16a25e11f2d8eea2ce47b9a26"
    ["0.10.0"]="fe759b90008cd9b70327cd9480365f10ad1e873cf7ede94f98f3593c09a16102cca74f3a29b60a035b14e6be1d9c6951f6e78b7df6b455845a263f62ac1d1831"
    ["0.9.2"]="d1630be5ef0f9a4ec9eea6e2758569f6f249781fb0afcba6673574767fcccfb4103df7e7fbf8901ddb7768c097340011e4ee157687c9506e557768b203419124"
    ["0.9.1"]="fd42b46c6797899c13a8b36c0af2f27c92ae9cae2eabec034901033c75b548933e06ed252ec5e2acf3026af1a762dee4ec75e06a4de4eeede671a56d1ef418e5"
    ["0.9.0"]="5d3eed441794c978206e5709340538667af1348f9e09d3a114cdb00a0f96b504bea51d32c0631aa6f679719d11df3789068ee02c68df287a886748737d172513"
    ["0.8.0"]="16706a73dc76c7c3fba2a4e86b4ac5001c9349e5d375ddaa8780944eb5276a92696f84966d2a12a258003cccb175971ea9ada11dfde3a2ee378baeab8a50cf3c"
    ["0.7.1"]="1ac22316f963c881f1629cb62e49d6e7baeac84a49c378d01442cc8f21116ade1b46f5cf7bf18d7908e85b59bdd3e55486e6932a72dcb5f13970afa75643c119"
    ["0.7.0"]="2e407eb220bd76c6f70eda040d0ec081ca44fa64abe13a71a9689a04328c96adf58a8cd22d97e9c34574d523e88de90c563c641b2835abb641e8079e84539b86"
    ["0.6.0"]="0d36a8370e36b00ce96a1b938038b5000b79301515152c52e40ad46e881ce8606812f11ec58e03d73a8d358b7957004cb664005bbc9c4baece343db34e10d467"
    ["0.5.1"]="cdea5fcf1747b22337722cbacbaa3723c0a98952f65210a48901706edd5243c779dcb49635d25fb89ee6f99926531a060c00982387936f36b8cfffb96de919cf"
    ["0.5.0"]="ee42c7c227e7711b017d0a1213518a6eb546bc0af99d9570fee5134980866c55e9c0020835c6e8df59e7e78f8221fa0161f4c8fb90892ebf8ca0371c48d7313f"
    ["0.4.1"]="a97cad37b59fe46755cbf0172edbb939a8e59f805a06c287202072925369fa5885daf7cd39ba38d5de0dde6fd45c66cc99ab11ce52d77935562effa82568c078"
    ["0.4.0"]="a448b227ee3086922df990dc4e79d7d159f2f8ace6c15045f7bc345f3a64a630d05bc40c65adf9b21164b965acfc7eab59bb5a602530ba3a4d383a47a18a4d63"
    ["0.3.0"]="bfaf57a31bb31cd120c4e8ec80df553d2213049760c9b8a9bc2c1295f968040112c8e53f4494ff3f9769dece1e573161669fef37351457106e616add321ec8dc"
    ["0.2.0"]="66e502ac2001a6cac8a06dc240cafc0ad2c6e66fcbc402d486b02096a0e71918b4d9db5142e2cb37befda29713348029fc052982dc0ea36a6e46e65bf9927778"
    ["0.1.0"]="a0dc4bcc9c2ebe8e446e4e70b5cc6afd3bec51f6f785aba1ffd94eace5bd20166af6e82845a9d48b0a36f7bdc31203930e931368f2e0b2fdb0a991d9ab25386d"
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