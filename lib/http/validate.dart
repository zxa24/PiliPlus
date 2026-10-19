import 'package:PiliPlus/http/api.dart';
import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:dio/dio.dart';

/// The risk-control captcha of a blocked search: the search goes out
/// anonymously, so the captcha does too (no csrf, which would bind it to the
/// account in login mode and tie the anonymous session to it).
abstract final class ValidateHttp {
  static Future<LoadingState<Map?>> gaiaVgateRegister(String vVoucher) async {
    final res = await Request().post(
      Api.gaiaVgateRegister,
      data: {
        'v_voucher': vVoucher,
      },
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
      ),
    );
    if (res.data['code'] == 0) {
      return Success(res.data['data']);
    } else {
      return Error(res.data['message']);
    }
  }

  static Future<LoadingState<Map?>> gaiaVgateValidate({
    required dynamic challenge,
    required dynamic seccode,
    required dynamic token,
    required dynamic validate,
  }) async {
    final res = await Request().post(
      Api.gaiaVgateValidate,
      data: {
        'challenge': challenge,
        'seccode': seccode,
        'token': token,
        'validate': validate,
      },
    );
    if (res.data['code'] == 0) {
      return Success(res.data['data']);
    } else {
      return Error(res.data['message']);
    }
  }
}
