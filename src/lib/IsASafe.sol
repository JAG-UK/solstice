// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {IProxy} from "@safe/proxies/SafeProxy.sol";

library IsASafe {
    error NotSafeProxy(address account);
    error UnusualSafeMasterCopy(address account, address masterCopy);

    function isProbablyASafe(address account) internal view {
        uint256 codesize = account.code.length;
        // observed Safe proxy codesize range is 110 (v1.0.0) to 171 (v1.3.0)
        require(codesize > 80 && codesize < 240, NotSafeProxy(account));
        address implementation = IProxy(account).masterCopy();
        // observed Safe masterCopy size is 20869 (v1.5.0) to 24421 (v1.4.1)
        require(implementation.code.length > 8000, UnusualSafeMasterCopy(account, implementation));
    }
}
